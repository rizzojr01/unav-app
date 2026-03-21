import 'dart:async';

import '../../../../core/models/pose.dart';
import 'ar_session_adapter.dart';

class StubArSessionAdapter implements ArSessionAdapter {
  final ArTrackingBackend _backend;
  final StreamController<Pose> _controller = StreamController<Pose>.broadcast();

  StubArSessionAdapter(this._backend);

  @override
  ArTrackingBackend get backend => _backend;

  @override
  Future<void> startSession() async {}

  @override
  Future<void> stopSession() async {}

  @override
  Stream<Pose> watchPose() => _controller.stream;

  Future<void> dispose() async {
    await _controller.close();
  }
}
