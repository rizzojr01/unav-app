import '../../../../core/models/pose.dart';

enum ArTrackingBackend {
  iosArKit,
  androidArCore,
  unsupported,
}

abstract class ArSessionAdapter {
  ArTrackingBackend get backend;

  Stream<Pose> watchPose();

  Future<void> startSession();

  Future<void> stopSession();
}
