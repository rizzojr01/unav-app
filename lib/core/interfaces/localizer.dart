import '../models/localized_pose.dart';
import '../models/pose.dart';

abstract class Localizer {
  Future<LocalizedPose> relocalize(Pose pose);
}
