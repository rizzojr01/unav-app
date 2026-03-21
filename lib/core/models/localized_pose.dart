import 'pose.dart';

class LocalizedPose extends Pose {
  final String floorKey;

  const LocalizedPose({
    required this.floorKey,
    required super.x,
    required super.y,
    super.z,
    super.heading,
    super.confidence,
    required super.timestamp,
  });
}
