import 'package:flutter/services.dart';

import '../../../../core/models/pose.dart';
import 'ar_channel_contract.dart';
import 'ar_session_adapter.dart';

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
        worldX: (data[ArChannelContract.worldXKey] as num?)?.toDouble(),
        worldY: (data[ArChannelContract.worldYKey] as num?)?.toDouble(),
        worldZ: (data[ArChannelContract.worldZKey] as num?)?.toDouble(),
        gravityX: (data[ArChannelContract.gravityXKey] as num?)?.toDouble(),
        gravityY: (data[ArChannelContract.gravityYKey] as num?)?.toDouble(),
        gravityZ: (data[ArChannelContract.gravityZKey] as num?)?.toDouble(),
        interfaceRotationDeg:
            (data[ArChannelContract.interfaceRotationDegKey] as num?)?.toDouble() ?? 0,
      );
    });
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
