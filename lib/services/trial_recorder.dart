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
import 'package:path_provider/path_provider.dart';

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
    final meta = <String, dynamic>{
      'trial_id': trialId,
      'schema_version': 1,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt.toIso8601String(),
      'end_reason': endReason.wire,
      'src_dst': context.toMap(),
      'platform': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'ar_backend': 'arkit',
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

  Future<void> _uploadTrial(Directory dir, String trialId) async {
    try {
      final zipBytes = await _zipDirectory(dir);
      await ApiService.uploadTrial(
        trialId: trialId,
        zipBytes: zipBytes,
        filename: '$trialId.zip',
      );
    } catch (_) {
      // Keep the directory on disk for later manual pull.
    }
  }

  Future<Uint8List> _zipDirectory(Directory dir) async {
    final archive = Archive();
    final base = dir.path;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(base.length + 1).replaceAll('\\', '/');
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
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
