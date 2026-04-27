// lib/services/trial_recorder.dart
//
// TrialRecorder — captures the raw data needed for offline research on
// ARKit drift and VPR-recovery behavior.
//
// Design (see EXPERIMENTS.md "Trial Recorder Schema for Drift Research"):
//
//   Each trial produces a self-contained directory on-device:
//
//     <app_docs>/trials/<trial_id>/
//       meta.json              (static metadata: device, src, dst, counts)
//       arkit.ndjson           (ARKit pose stream, ~30 Hz, every ARFrame)
//       frames/f_NNNNNN.jpg    (continuous camera frames throttled to ~2 Hz)
//       queries/q_NNNN.jpg     (high-quality JPEG captured when user taps)
//       queries/q_NNNN.json    ({seq, ar_t_at_capture, ar_pose_at_capture,
//                                frame_index_at_capture, server})
//
//   At end-of-trial the directory is zipped and POSTed to the backend.
//
// This runs in parallel with — and does NOT disturb — the existing
// "tap → capture → POST /run_task" flow. The user-facing VPR query keeps
// working exactly as before; TrialRecorder only listens to the same
// ARKit stream and piggybacks on each capture event.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:device_info_plus/device_info_plus.dart';

import '../api/api_service.dart';
import '../core/models/pose.dart';
import '../features/navigation/infrastructure/tracking/native_ar_session_adapter.dart';

/// End-reason tags stored in meta.json.
enum TrialEndReason {
  arrived,
  cancelled,
  destinationChanged,
  error,
  backgrounded,
}

extension on TrialEndReason {
  String get wire {
    switch (this) {
      case TrialEndReason.arrived:
        return 'arrived';
      case TrialEndReason.cancelled:
        return 'cancelled';
      case TrialEndReason.destinationChanged:
        return 'destination_changed';
      case TrialEndReason.error:
        return 'error';
      case TrialEndReason.backgrounded:
        return 'backgrounded';
    }
  }
}

/// Static context about the destination / source chosen for the trial.
class TrialContext {
  final String placeId;
  final String placeName;
  final String buildingId;
  final String buildingName;
  final String floorId;
  final String floorName;
  final String destinationId;
  final String destinationName;

  const TrialContext({
    required this.placeId,
    required this.placeName,
    required this.buildingId,
    required this.buildingName,
    required this.floorId,
    required this.floorName,
    required this.destinationId,
    required this.destinationName,
  });

  Map<String, dynamic> toMap() => {
    'place_id': placeId,
    'place_name': placeName,
    'building_id': buildingId,
    'building_name': buildingName,
    'floor_id': floorId,
    'floor_name': floorName,
    'destination_id': destinationId,
    'destination_name': destinationName,
  };
}

/// Singleton recording a single active trial. All public methods are safe to
/// call regardless of whether a trial is currently active — they will simply
/// no-op if no trial is started.
class TrialRecorder {
  TrialRecorder._();
  static final TrialRecorder instance = TrialRecorder._();

  // ---------- lifecycle state ----------

  bool get isActive => _activeTrialId != null;
  String? get activeTrialId => _activeTrialId;

  String? _activeTrialId;
  Directory? _trialDir;
  Directory? _framesDir;
  Directory? _queriesDir;
  DateTime? _startedAt;
  TrialContext? _context;
  double? _firstArTimestamp;

  IOSink? _arkitSink;
  int _poseRowCount = 0;
  int _frameCount = 0;
  int _queryCount = 0;

  StreamSubscription<Pose>? _poseSub;
  Timer? _frameTimer;
  NativeArSessionAdapter? _adapter;

  // Last seen arTimestamp (so we can throttle to ~2 Hz for frames).
  double? _lastFrameArT;
  static const double _minFrameIntervalSec = 0.5; // 2 Hz

  // ---------- public API ----------

  /// Begin a new trial. Creates the on-device directory, opens the pose
  /// ndjson sink, subscribes to the ARKit stream, and starts the 2 Hz frame
  /// capture loop. If another trial is currently active, it is ended with
  /// [TrialEndReason.destinationChanged] first.
  Future<void> startTrial({
    required TrialContext context,
    required Stream<Pose> poseStream,
    required NativeArSessionAdapter adapter,
  }) async {
    if (isActive) {
      await endTrial(TrialEndReason.destinationChanged);
    }

    final id = _generateTrialId();
    final docs = await getApplicationDocumentsDirectory();
    final trialDir = Directory('${docs.path}/trials/$id');
    final framesDir = Directory('${trialDir.path}/frames');
    final queriesDir = Directory('${trialDir.path}/queries');
    await framesDir.create(recursive: true);
    await queriesDir.create(recursive: true);

    final arkitFile = File('${trialDir.path}/arkit.ndjson');
    final sink = arkitFile.openWrite(mode: FileMode.writeOnlyAppend);

    _activeTrialId = id;
    _trialDir = trialDir;
    _framesDir = framesDir;
    _queriesDir = queriesDir;
    _startedAt = DateTime.now().toUtc();
    _context = context;
    _arkitSink = sink;
    _adapter = adapter;
    _firstArTimestamp = null;
    _poseRowCount = 0;
    _frameCount = 0;
    _queryCount = 0;
    _lastFrameArT = null;

    // Subscribe to pose stream in parallel with whatever else consumes it.
    // Flutter broadcast streams allow multiple listeners.
    _poseSub = poseStream.listen(
      _onPose,
      onError: (_) {/* swallow — research logging is best-effort */},
    );

    // Poll native capture at a fixed interval. We can't hook a camera frame
    // callback in Dart, but 2 Hz pulls from captureCurrentFrameWithPose give
    // us enough temporal density for drift research (at 1 m/s walking that's
    // one frame every 0.5 m, matching our training distribution).
    _frameTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_captureFrameIfReady());
    });
  }

  /// Called by navigation_screen whenever the user successfully fires a VPR
  /// query. We persist:
  ///   - the high-quality JPEG returned from the native side
  ///   - the contemporaneous ARKit pose and arTimestamp
  ///   - the server's response (floorplan_pose, n_inliers, ...)
  ///   - a pointer back into frames/ (frame_index_at_capture) so research
  ///     code can find the closest 2 Hz background frame
  Future<void> recordQuery({
    required NativeCaptureResult capture,
    required Map<String, dynamic> serverResponse,
  }) async {
    if (!isActive) return;
    final queriesDir = _queriesDir;
    if (queriesDir == null) return;

    _queryCount += 1;
    final seq = _queryCount;
    final stem = 'q_${seq.toString().padLeft(4, '0')}';

    final jpegFile = File('${queriesDir.path}/$stem.jpg');
    final jsonFile = File('${queriesDir.path}/$stem.json');
    await jpegFile.writeAsBytes(capture.jpegBytes, flush: false);

    final trialT = _firstArTimestamp == null
        ? 0.0
        : capture.arTimestamp - _firstArTimestamp!;

    final payload = <String, dynamic>{
      'seq': seq,
      'ar_t_at_capture': capture.arTimestamp,
      'trial_t_at_capture': trialT,
      'wall_ms_at_capture': capture.timestampMillis,
      // Rough pointer into frames/; research post-processing can refine by
      // matching arTimestamp against arkit.ndjson.
      'frame_index_at_capture': _frameCount,
      'ar_pose_at_capture': {
        'pos': [capture.x, capture.y, capture.z],
        'world_pos': [capture.worldX, capture.worldY, capture.worldZ],
        'quat': [capture.qw, capture.qx, capture.qy, capture.qz],
        'heading_deg': capture.headingDeg,
        'tracking_state': capture.trackingState,
        'interface_rotation_deg': capture.interfaceRotationDeg,
      },
      'server': _sanitizeServerResponse(serverResponse),
    };
    await jsonFile.writeAsString(
      jsonEncode(payload),
      flush: false,
    );
  }

  /// Finalize the current trial, flush everything to disk, write meta.json,
  /// zip the folder, and POST it to the backend. Best-effort — if anything
  /// fails (disk full, network down, backend 500) we keep the on-disk folder
  /// so it can be retried later.
  Future<void> endTrial(TrialEndReason reason) async {
    if (!isActive) return;

    _frameTimer?.cancel();
    _frameTimer = null;
    await _poseSub?.cancel();
    _poseSub = null;

    try {
      await _arkitSink?.flush();
    } catch (_) {}
    try {
      await _arkitSink?.close();
    } catch (_) {}
    _arkitSink = null;

    final dir = _trialDir;
    final ctx = _context;
    final startedAt = _startedAt;
    final id = _activeTrialId;
    if (dir != null && ctx != null && startedAt != null && id != null) {
      await _writeMeta(
        dir: dir,
        trialId: id,
        context: ctx,
        startedAt: startedAt,
        endedAt: DateTime.now().toUtc(),
        endReason: reason,
      );
      // Upload in background; keep the directory on disk regardless so we
      // never lose data.
      unawaited(_uploadTrial(dir, id));
    }

    _activeTrialId = null;
    _trialDir = null;
    _framesDir = null;
    _queriesDir = null;
    _startedAt = null;
    _context = null;
    _adapter = null;
    _firstArTimestamp = null;
    _poseRowCount = 0;
    _frameCount = 0;
    _queryCount = 0;
    _lastFrameArT = null;
  }

  // ---------- internals ----------

  void _onPose(Pose pose) {
    final sink = _arkitSink;
    if (sink == null) return;
    final arT = pose.arTimestamp;
    if (arT == null) {
      // Non-native backend. Skip; we rely on ARFrame timestamps.
      return;
    }
    _firstArTimestamp ??= arT;
    final trialT = arT - _firstArTimestamp!;
    final row = <String, dynamic>{
      'ar_t': arT,
      'trial_t': trialT,
      'wall_ms': pose.timestamp.millisecondsSinceEpoch,
      'pos': [pose.x, pose.y, pose.z],
      if (pose.worldX != null && pose.worldY != null && pose.worldZ != null)
        'world_pos': [pose.worldX, pose.worldY, pose.worldZ],
      if (pose.qw != null &&
          pose.qx != null &&
          pose.qy != null &&
          pose.qz != null)
        'quat': [pose.qw, pose.qx, pose.qy, pose.qz],
      'heading_deg': pose.heading,
      if (pose.trackingState != null) 'tracking_state': pose.trackingState,
      'interface_rotation_deg': pose.interfaceRotationDeg,
      'confidence': pose.confidence,
    };
    try {
      sink.writeln(jsonEncode(row));
      _poseRowCount += 1;
    } catch (_) {
      // disk full or similar — just drop the row.
    }
  }

  Future<void> _captureFrameIfReady() async {
    if (!isActive) return;
    final adapter = _adapter;
    final framesDir = _framesDir;
    if (adapter == null || framesDir == null) return;
    try {
      final cap = await adapter.captureWithPose();
      if (cap == null) return;
      // Throttle: if the ARKit clock says less than _minFrameIntervalSec has
      // passed since the last recorded frame, skip. This is belt-and-braces
      // on top of the 500 ms Timer.
      if (_lastFrameArT != null &&
          cap.arTimestamp - _lastFrameArT! < _minFrameIntervalSec - 0.05) {
        return;
      }
      _lastFrameArT = cap.arTimestamp;
      final idx = _frameCount;
      _frameCount += 1;
      final name = 'f_${idx.toString().padLeft(6, '0')}.jpg';
      final f = File('${framesDir.path}/$name');
      // Write without flush for speed; file system will sync on close.
      await f.writeAsBytes(cap.jpegBytes, flush: false);
    } catch (_) {
      // Ignore — recording is best-effort.
    }
  }

  Map<String, dynamic> _sanitizeServerResponse(Map<String, dynamic> raw) {
    // We only keep the fields that matter for research (pose,
    // inliers, route, status). This avoids persisting oversized debug blobs.
    const keep = <String>{
      'success',
      'error',
      'reason',
      'stage',
      'floorplan_pose',
      'result',
      'cmds',
      'best_map_key',
      'n_inliers',
      'num_inliers',
      'inlier_count',
      'retrieval_score',
      'top_candidates',
      'timings',
      '_exec_time',
    };
    final out = <String, dynamic>{};
    raw.forEach((k, v) {
      if (keep.contains(k)) out[k] = v;
    });
    return out;
  }

  Future<void> _writeMeta({
    required Directory dir,
    required String trialId,
    required TrialContext context,
    required DateTime startedAt,
    required DateTime endedAt,
    required TrialEndReason endReason,
  }) async {
    // Collect device hardware info
    final deviceInfo = DeviceInfoPlugin();
    Map<String, dynamic> deviceData = {};
    if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      deviceData = {
        'device_model': ios.utsname.machine,     // e.g. "iPhone16,1"
        'device_name': ios.name,                   // e.g. "Anbang's iPhone"
        'device_model_name': ios.model,            // e.g. "iPhone"
        'system_name': ios.systemName,             // e.g. "iOS"
        'system_version': ios.systemVersion,       // e.g. "18.0"
        'is_physical_device': ios.isPhysicalDevice,
      };
    } else if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      deviceData = {
        'device_model': android.model,             // e.g. "Pixel 7"
        'device_brand': android.brand,             // e.g. "google"
        'device_manufacturer': android.manufacturer,
        'device_hardware': android.hardware,
        'system_version': android.version.release,  // e.g. "14"
        'sdk_int': android.version.sdkInt,
        'is_physical_device': android.isPhysicalDevice,
      };
    }

    final meta = <String, dynamic>{
      'trial_id': trialId,
      'schema_version': 2,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt.toIso8601String(),
      'end_reason': endReason.wire,
      'src_dst': context.toMap(),
      'platform': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'device': deviceData,
      'ar_backend': Platform.isIOS ? 'arkit' : 'arcore',
      'pose_stream_expected_hz': 30,
      'frame_capture_target_hz': 2,
      'counts': {
        'pose_rows': _poseRowCount,
        'frames': _frameCount,
        'queries': _queryCount,
      },
    };
    final f = File('${dir.path}/meta.json');
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  }

  // ---------- Upload pipeline (chunked + resumable) ----------
  //
  // The trial archive is uploaded as a sequence of fixed-size chunks
  // (`_uploadChunkSize` bytes each). Each chunk is a separate HTTP POST,
  // so a packet drop kills only the in-flight chunk rather than the whole
  // upload — and the server publishes the trial only after *all* chunks
  // arrive and the SHA-1 of the assembled zip matches what we declared.
  //
  // We persist the staged zip and its SHA-1 inside the trial directory
  // (as `upload.zip` and `upload.sha1`), and we drop a `.uploaded`
  // sentinel file once the server reports the trial as fully extracted.
  // On app start, `resumePendingUploads()` scans for trials that are
  // finalized (have meta.json) but not yet uploaded (no `.uploaded`) and
  // re-runs the chunked-upload pipeline against `/trials/chunk_status` —
  // skipping any chunks the server already has, sending only what's
  // missing.

  static const int _uploadChunkSize = 5 * 1024 * 1024; // 5 MiB
  static const int _maxChunkRetries = 5;
  static const String _stagedZipName = 'upload.zip';
  static const String _stagedSha1Name = 'upload.sha1';
  static const String _uploadedSentinelName = '.uploaded';

  // Guards the resume scan from running concurrently in two callers.
  static bool _resumeInFlight = false;

  /// Scan `<app_docs>/trials/` for finalized-but-not-yet-uploaded trials
  /// and resume their uploads in the background. Safe to call from
  /// `main()` on every app start.
  static Future<void> resumePendingUploads() async {
    if (_resumeInFlight) return;
    _resumeInFlight = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}/trials');
      if (!await root.exists()) return;
      await for (final ent in root.list(followLinks: false)) {
        if (ent is! Directory) continue;
        final dir = ent;
        final trialId = dir.path.split(Platform.pathSeparator).last;
        // Only attempt trials that have been finalized (meta.json present).
        final meta = File('${dir.path}/meta.json');
        if (!await meta.exists()) continue;
        final sentinel = File('${dir.path}/$_uploadedSentinelName');
        if (await sentinel.exists()) continue;
        // Fire-and-forget; each upload manages its own retry loop and
        // never throws.
        unawaited(instance._uploadTrial(dir, trialId));
      }
    } catch (_) {
      // Best-effort; leave failures for the next app start.
    } finally {
      _resumeInFlight = false;
    }
  }

  Future<void> _uploadTrial(Directory dir, String trialId) async {
    final sentinel = File('${dir.path}/$_uploadedSentinelName');
    if (await sentinel.exists()) return;

    final zipFile = File('${dir.path}/$_stagedZipName');
    final sha1File = File('${dir.path}/$_stagedSha1Name');

    // 1. Stage the zip (idempotent: re-uses prior staged zip on resume).
    await _reportStage(trialId, 'zip_started');
    String sha1Hex;
    int sizeFull;
    try {
      if (!await zipFile.exists()) {
        await _zipDirectoryToFile(dir, zipFile);
      }
      if (await sha1File.exists()) {
        sha1Hex = (await sha1File.readAsString()).trim();
      } else {
        sha1Hex = await _sha1OfFile(zipFile);
        await sha1File.writeAsString(sha1Hex);
      }
      sizeFull = await zipFile.length();
    } catch (e, st) {
      await _reportStage(trialId, 'failed', error: 'zip: $e\n$st');
      return;
    }

    if (sizeFull <= 0) {
      await _reportStage(trialId, 'failed', error: 'zip is empty');
      return;
    }

    await _reportStage(trialId, 'upload_started', zipBytes: sizeFull);

    // 2. Idempotency: did a previous attempt's response merely get lost?
    final exists = await ApiService.trialExists(trialId);
    if (exists['exists'] == true) {
      await _markUploaded(trialId, zipFile, sha1File, sentinel, sizeFull);
      return;
    }

    // 3. Resume: ask the server which chunks it already has.
    final chunkTotal = (sizeFull + _uploadChunkSize - 1) ~/ _uploadChunkSize;
    Set<int> alreadyHave = <int>{};
    final status = await ApiService.getTrialChunkStatus(trialId);
    if (status['completed'] == true) {
      await _markUploaded(trialId, zipFile, sha1File, sentinel, sizeFull);
      return;
    }
    final received = status['chunks_received'];
    if (received is List) {
      // Only honor the server's resume hint when the chunk_total agrees;
      // otherwise the client picked a different chunk size since last try
      // and the server's chunks won't line up with ours.
      final serverTotal = status['chunk_total'];
      if (serverTotal == null || serverTotal == chunkTotal) {
        for (final v in received) {
          if (v is int) alreadyHave.add(v);
        }
      }
    }

    // 4. Send any missing chunks, with bounded retries per chunk.
    bool serverSaysCompleted = false;
    Map<String, dynamic> lastResult = const {};
    final raf = await zipFile.open();
    try {
      for (int idx = 0; idx < chunkTotal; idx++) {
        if (alreadyHave.contains(idx)) continue;
        final start = idx * _uploadChunkSize;
        final remaining = sizeFull - start;
        final n = remaining < _uploadChunkSize ? remaining : _uploadChunkSize;
        await raf.setPosition(start);
        final chunkBytes = Uint8List.fromList(await raf.read(n));

        bool ok = false;
        for (int attempt = 0; attempt < _maxChunkRetries && !ok; attempt++) {
          if (attempt > 0) {
            // Exponential backoff: 0.5s, 1s, 2s, 4s.
            final delayMs = 500 << (attempt - 1);
            await Future.delayed(Duration(milliseconds: delayMs));
          }
          lastResult = await ApiService.uploadTrialChunk(
            trialId: trialId,
            chunkIdx: idx,
            chunkTotal: chunkTotal,
            sha1Full: sha1Hex,
            sizeFull: sizeFull,
            chunkBytes: chunkBytes,
          );
          final status = lastResult['_status'];
          // Only treat 2xx as success. 409 (manifest conflict) means our
          // local zip changed since last attempt — bail to give the next
          // resume a clean slate.
          if (status is int && status == 409) {
            await _resetStagedArtifacts(zipFile, sha1File);
            await _reportStage(trialId, 'failed',
                error: 'manifest conflict (server has different sha1/size)',
                zipBytes: sizeFull);
            return;
          }
          if (lastResult['error'] == null &&
              (status == null || (status is int && status >= 200 && status < 300))) {
            ok = true;
          }
        }
        if (!ok) {
          await _reportStage(trialId, 'failed',
              error: 'chunk $idx after $_maxChunkRetries attempts: '
                  '${lastResult['error']}',
              zipBytes: sizeFull);
          return; // leave staged zip on disk; next resume will pick up
        }
        if (lastResult['completed'] == true) {
          serverSaysCompleted = true;
          break;
        }
      }
    } finally {
      await raf.close();
    }

    // 5. Confirm. Either the last chunk's response said completed, or we
    // ask /trials/exists once more (covers the case where chunks arrived
    // out of order and the final assembly happened on a different request).
    if (!serverSaysCompleted) {
      final finalCheck = await ApiService.trialExists(trialId);
      serverSaysCompleted = finalCheck['exists'] == true;
    }
    if (serverSaysCompleted) {
      await _markUploaded(trialId, zipFile, sha1File, sentinel, sizeFull);
    } else {
      await _reportStage(trialId, 'failed',
          error: 'all chunks sent but server has not completed assembly',
          zipBytes: sizeFull);
    }
  }

  Future<void> _markUploaded(
    String trialId,
    File zipFile,
    File sha1File,
    File sentinel,
    int sizeFull,
  ) async {
    try {
      await sentinel.create(recursive: false);
    } catch (_) {}
    await _reportStage(trialId, 'done', zipBytes: sizeFull);
    // Free the duplicated zip storage; the original frames/queries/arkit
    // files remain so we still have an offline copy of the trial.
    try {
      await zipFile.delete();
    } catch (_) {}
    try {
      await sha1File.delete();
    } catch (_) {}
  }

  Future<void> _resetStagedArtifacts(File zipFile, File sha1File) async {
    try {
      await zipFile.delete();
    } catch (_) {}
    try {
      await sha1File.delete();
    } catch (_) {}
  }

  Future<void> _reportStage(String trialId, String stage,
      {String error = '', int zipBytes = 0}) async {
    try {
      await ApiService.reportUploadAttempt(
        trialId: trialId,
        stage: stage,
        error: error,
        zipBytes: zipBytes,
      );
    } catch (_) {}
  }

  /// Stream the trial directory into a zip file on disk. Skips our own
  /// upload artifacts (`upload.zip`, `upload.sha1`, `.uploaded`) so a
  /// resume run doesn't accidentally include them.
  Future<void> _zipDirectoryToFile(Directory dir, File zipFile) async {
    final archive = Archive();
    final base = dir.path;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(base.length + 1).replaceAll('\\', '/');
      // Skip upload-pipeline artifacts to avoid recursive inclusion across
      // retries.
      if (rel == _stagedZipName ||
          rel == '$_stagedZipName.part' ||
          rel == _stagedSha1Name ||
          rel == _uploadedSentinelName) {
        continue;
      }
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    final part = File('${zipFile.path}.part');
    await part.writeAsBytes(encoded, flush: true);
    await part.rename(zipFile.path);
  }

  /// Streamed SHA-1 over a file. Avoids loading the whole zip into RAM
  /// (which can be ≥100 MiB on a long trial) just to compute the digest.
  Future<String> _sha1OfFile(File f) async {
    final digest = await sha1.bind(f.openRead()).first;
    return digest.toString();
  }

  String _generateTrialId() {
    // Human-readable timestamp + 6 hex chars of randomness. UUID-style
    // uniqueness is overkill for our use.
    final now = DateTime.now().toUtc();
    final ts = now.toIso8601String().replaceAll(RegExp(r'[:.\-]'), '');
    final rnd = Random.secure().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return 'trial_${ts}_$rnd';
  }
}
