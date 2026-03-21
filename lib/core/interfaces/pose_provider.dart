import '../models/pose.dart';

abstract class PoseProvider {
  Stream<Pose> watchPose();
  Future<void> start();
  Future<void> stop();
}
