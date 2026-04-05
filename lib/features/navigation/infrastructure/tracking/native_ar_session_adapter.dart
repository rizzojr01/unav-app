import 'package:flutter/services.dart';

import '../../../../core/models/pose.dart';
import 'ar_channel_contract.dart';
import 'ar_session_adapter.dart';

/// Result of [NativeArSessionAdapter.captureWithPose].
///
/// Pairs a JPEG of the current ARFrame with the contemporaneous ARKit pose,
/// the ARFrame native timestamp, and the AR tracking state. Used by
/// [TrialRecorder] to index VPR query captures against the pose ndjson.
class NativeCaptureResult {
  final Uint8List jpegBytes;
  final double arTimestamp;
  final int timestampMillis;
  final double x;
  final double y;
  final double z;
  final double worldX;
  final double worldY;
  final double worldZ;
  final double qw;
  final double qx;
  final double qy;
  final double qz;
  final double headingDeg;
  final String trackingState;
  final double interfaceRotationDeg;

  const NativeCaptureResult({
    required this.jpegBytes,
    required this.arTimestamp,
    required this.timestampMillis,
    required this.x,
    required this.y,
    required this.z,
    required this.worldX,
    required this.worldY,
    required this.worldZ,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.headingDeg,
    required this.trackingState,
    required this.interfaceRotationDeg,
  });
}

class NativeArSessionAdapter implements ArSessionAdapter {
  final ArTrackingBackend _backend;
  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  const NativeArSessionAdapter({
    required ArTrackingBackend backend,
    MethodChannel methodChannel = const MethodChannel(ArChannelContract.methodChannel),
    EventChannel eventChannel = const EventChannel(ArChannelContract.eventChannel),
  })  : _backend = backend,
        _methodChannel = methodChannel,
        _eventChannel = eventChannel;

  @override
  ArTrackingBackend get backend => _backend;

  @override
  Future<void> startSession() async {
    await _methodChannel.invokeMethod<void>(
      ArChannelContract.startSessionMethod,
      {
        ArChannelContract.backendKey: backend.name,
      },
    );
  }

  @override
  Future<void> stopSession() async {
    await _methodChannel.invokeMethod<void>(
      ArChannelContract.stopSessionMethod,
      {
        ArChannelContract.backendKey: backend.name,
      },
    );
  }

  @override
  Stream<Pose> watchPose() {
    return _eventChannel.receiveBroadcastStream(
      {
        ArChannelContract.backendKey: backend.name,
      },
    ).map((event) {
      final data = Map<String, dynamic>.from(event as Map);
      return Pose(
        x: (data[ArChannelContract.xKey] as num?)?.toDouble() ?? 0,
        y: (data[ArChannelContract.yKey] as num?)?.toDouble() ?? 0,
        z: (data[ArChannelContract.zKey] as num?)?.toDouble() ?? 0,
        heading: (data[ArChannelContract.headingKey] as num?)?.toDouble() ?? 0,
        confidence: (data[ArChannelContract.confidenceKey] as num?)?.toDouble() ?? 1,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (data[ArChannelContract.timestampKey] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
        arTimestamp:
            (data[ArChannelContract.arTimestampKey] as num?)?.toDouble(),
        worldX: (data[ArChannelContract.worldXKey] as num?)?.toDouble(),
        worldY: (data[ArChannelContract.worldYKey] as num?)?.toDouble(),
        worldZ: (data[ArChannelContract.worldZKey] as num?)?.toDouble(),
        qw: (data[ArChannelContract.quatWKey] as num?)?.toDouble(),
        qx: (data[ArChannelContract.quatXKey] as num?)?.toDouble(),
        qy: (data[ArChannelContract.quatYKey] as num?)?.toDouble(),
        qz: (data[ArChannelContract.quatZKey] as num?)?.toDouble(),
        trackingState: data[ArChannelContract.trackingStateKey] as String?,
        gravityX: (data[ArChannelContract.gravityXKey] as num?)?.toDouble(),
        gravityY: (data[ArChannelContract.gravityYKey] as num?)?.toDouble(),
        gravityZ: (data[ArChannelContract.gravityZKey] as num?)?.toDouble(),
        interfaceRotationDeg:
            (data[ArChannelContract.interfaceRotationDegKey] as num?)?.toDouble() ?? 0,
      );
    });
  }

  /// Captures the current ARFrame along with its native ARFrame.timestamp and
  /// the contemporaneous camera pose. Returns null if the native side has no
  /// frame available yet.
  ///
  /// This is the foundation of [TrialRecorder]'s "query ↔ pose alignment":
  /// the returned arTimestamp can be matched against rows in arkit.ndjson to
  /// index exactly which pose was current when the user fired a VPR query.
  Future<NativeCaptureResult?> captureWithPose() async {
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      ArChannelContract.captureCurrentFrameWithPoseMethod,
      {
        ArChannelContract.backendKey: backend.name,
      },
    );
    if (raw == null) return null;
    final data = Map<String, dynamic>.from(raw);
    final bytes = data[ArChannelContract.jpegBytesKey];
    if (bytes is! Uint8List) return null;
    return NativeCaptureResult(
      jpegBytes: bytes,
      arTimestamp:
          (data[ArChannelContract.arTimestampKey] as num?)?.toDouble() ?? 0,
      timestampMillis:
          (data[ArChannelContract.timestampKey] as num?)?.toInt() ?? 0,
      x: (data[ArChannelContract.xKey] as num?)?.toDouble() ?? 0,
      y: (data[ArChannelContract.yKey] as num?)?.toDouble() ?? 0,
      z: (data[ArChannelContract.zKey] as num?)?.toDouble() ?? 0,
      worldX: (data[ArChannelContract.worldXKey] as num?)?.toDouble() ?? 0,
      worldY: (data[ArChannelContract.worldYKey] as num?)?.toDouble() ?? 0,
      worldZ: (data[ArChannelContract.worldZKey] as num?)?.toDouble() ?? 0,
      qw: (data[ArChannelContract.quatWKey] as num?)?.toDouble() ?? 1,
      qx: (data[ArChannelContract.quatXKey] as num?)?.toDouble() ?? 0,
      qy: (data[ArChannelContract.quatYKey] as num?)?.toDouble() ?? 0,
      qz: (data[ArChannelContract.quatZKey] as num?)?.toDouble() ?? 0,
      headingDeg:
          (data[ArChannelContract.headingKey] as num?)?.toDouble() ?? 0,
      trackingState:
          (data[ArChannelContract.trackingStateKey] as String?) ?? 'unknown',
      interfaceRotationDeg:
          (data[ArChannelContract.interfaceRotationDegKey] as num?)
                  ?.toDouble() ??
              0,
    );
  }

  Future<Map<String, dynamic>> getCapabilities() async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      ArChannelContract.getCapabilitiesMethod,
      {
        ArChannelContract.backendKey: backend.name,
      },
    );
    return result == null ? <String, dynamic>{} : Map<String, dynamic>.from(result);
  }
}
