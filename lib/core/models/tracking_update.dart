import 'dart:ui';

import 'audio_cue_direction.dart';
import 'guidance_event.dart';
import 'localized_pose.dart';
import 'tracking_state.dart';

class TrackingUpdate {
  final List<Offset> trackedPath;
  final int currentSegmentIndex;
  final int nextWaypointIndex;
  final double remainingDistancePx;
  final double distanceToNextWaypointPx;
  final double distanceToPathPx;
  final double offRouteSeverity;
  final AudioCueDirection offRouteDirection;
  final LocalizedPose? localizedPose;
  final TrackingState state;
  final List<GuidanceEvent> events;

  const TrackingUpdate({
    required this.trackedPath,
    required this.currentSegmentIndex,
    required this.nextWaypointIndex,
    required this.remainingDistancePx,
    required this.distanceToNextWaypointPx,
    required this.distanceToPathPx,
    this.offRouteSeverity = 0,
    this.offRouteDirection = AudioCueDirection.center,
    required this.localizedPose,
    required this.state,
    this.events = const [],
  });
}
