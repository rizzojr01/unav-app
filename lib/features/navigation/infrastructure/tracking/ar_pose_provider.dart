import '../../../../core/interfaces/pose_provider.dart';
import '../../../../core/models/pose.dart';
import 'ar_session_adapter.dart';

class ArPoseProvider implements PoseProvider {
  final ArSessionAdapter adapter;

  const ArPoseProvider({
    required this.adapter,
  });

  @override
  Future<void> start() => adapter.startSession();

  @override
  Future<void> stop() => adapter.stopSession();

  @override
  Stream<Pose> watchPose() => adapter.watchPose();
}
