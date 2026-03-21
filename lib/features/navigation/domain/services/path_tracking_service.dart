import 'dart:math' as math;
import 'dart:ui';

import '../../../../core/interfaces/path_tracker.dart';
import '../../../../core/models/audio_cue_direction.dart';
import '../../../../core/models/guidance_event.dart';
import '../../../../core/models/navigation_route.dart';
import '../../../../core/models/navigation_session.dart';
import '../../../../core/models/tracking_state.dart';
import '../../../../core/models/tracking_update.dart';

class PathTrackingService implements PathTracker {
  static const double _offRouteThresholdPx = 72;
  static const double _approachThresholdPx = 120;
  static const double _turnNowThresholdPx = 40;

  const PathTrackingService();

  @override
  TrackingUpdate update({
    required NavigationSession session,
    required NavigationRoute route,
  }) {
    final pose = session.currentPose;
    final anchor = session.localizedAnchorPose;
    if (pose == null || anchor == null || route.points.isEmpty) {
      return TrackingUpdate(
        trackedPath: route.points,
        currentSegmentIndex: session.currentSegmentIndex,
        nextWaypointIndex: session.nextWaypointIndex,
        remainingDistancePx: _measurePathDistance(route.points),
        distanceToNextWaypointPx: 0,
        distanceToPathPx: 0,
        localizedPose: pose,
        state: TrackingState.localizing,
      );
    }

    final currentPoint = Offset(pose.x, pose.y);
    final fixedPolyline = <Offset>[
      Offset(anchor.x, anchor.y),
      ...route.points,
    ];
    final projection = _projectToPath(fixedPolyline, currentPoint);
    final activeWaypointIndex = projection.segmentIndex.clamp(0, route.points.length - 1);

    final trackedPath = <Offset>[
      currentPoint,
      ...route.points.skip(activeWaypointIndex),
    ];

    final distanceToNextWaypointPx =
        (route.points[activeWaypointIndex] - currentPoint).distance;
    final offRouteDirection = _computeOffRouteDirection(
      headingDeg: pose.heading,
      currentPoint: currentPoint,
      projectedPoint: projection.projectedPoint,
    );
    final offRouteSeverity = _normalizedOffRouteSeverity(projection.distanceToPathPx);
    final events = _buildEvents(
      projection: projection,
      trackedPath: trackedPath,
      distanceToNextWaypointPx: distanceToNextWaypointPx,
      previousWaypointIndex: session.nextWaypointIndex,
      activeWaypointIndex: activeWaypointIndex,
      waypointCount: route.points.length,
    );

    final state = projection.distanceToPathPx > _offRouteThresholdPx
        ? TrackingState.offRoute
        : distanceToNextWaypointPx <= _turnNowThresholdPx &&
                activeWaypointIndex == route.points.length - 1
            ? TrackingState.arrived
            : TrackingState.tracking;

    return TrackingUpdate(
      trackedPath: trackedPath,
      currentSegmentIndex: activeWaypointIndex,
      nextWaypointIndex: activeWaypointIndex,
      remainingDistancePx: _measurePathDistance(trackedPath),
      distanceToNextWaypointPx: distanceToNextWaypointPx,
      distanceToPathPx: projection.distanceToPathPx,
      offRouteSeverity: offRouteSeverity,
      offRouteDirection: offRouteDirection,
      localizedPose: pose,
      state: state,
      events: events,
    );
  }

  List<GuidanceEvent> _buildEvents({
    required _PathProjection projection,
    required List<Offset> trackedPath,
    required double distanceToNextWaypointPx,
    required int previousWaypointIndex,
    required int activeWaypointIndex,
    required int waypointCount,
  }) {
    if (projection.distanceToPathPx > _offRouteThresholdPx) {
      return const [
        GuidanceEvent(
          type: GuidanceEventType.offRoute,
          message: 'Off route. Recenter and prepare to relocalize.',
        ),
      ];
    }

    if (activeWaypointIndex > previousWaypointIndex) {
      return [
        GuidanceEvent(
          type: GuidanceEventType.waypointAdvanced,
          message:
              'Passed waypoint $previousWaypointIndex. Next waypoint is $activeWaypointIndex.',
        ),
      ];
    }

    if (activeWaypointIndex < previousWaypointIndex) {
      return [
        GuidanceEvent(
          type: GuidanceEventType.waypointRegressed,
          message:
              'Moved back before waypoint $previousWaypointIndex. Restoring waypoint $activeWaypointIndex.',
        ),
      ];
    }

    if (distanceToNextWaypointPx <= _turnNowThresholdPx) {
      if (activeWaypointIndex == waypointCount - 1) {
        return const [
          GuidanceEvent(
            type: GuidanceEventType.arrived,
            message: 'Arrived at destination.',
          ),
        ];
      }
      return [
        GuidanceEvent(
          type: GuidanceEventType.turnNow,
          message: 'Turn now at waypoint $activeWaypointIndex.',
        ),
      ];
    }

    if (distanceToNextWaypointPx <= _approachThresholdPx) {
      return [
        GuidanceEvent(
          type: GuidanceEventType.approachingWaypoint,
          message: 'Approaching waypoint $activeWaypointIndex.',
        ),
      ];
    }

    return const [
      GuidanceEvent(type: GuidanceEventType.trackingUpdated, message: ''),
    ];
  }

  double _measurePathDistance(List<Offset> points) {
    if (points.length < 2) return 0;
    double total = 0;
    for (int i = 0; i < points.length - 1; i++) {
      total += (points[i + 1] - points[i]).distance;
    }
    return total;
  }

  _PathProjection _projectToPath(List<Offset> path, Offset currentPose) {
    double bestDistanceSq = double.infinity;
    Offset bestProjection = path.first;
    int bestSegmentIndex = 0;

    for (int i = 0; i < path.length - 1; i++) {
      final a = path[i];
      final b = path[i + 1];
      final ab = b - a;
      final abLenSq = ab.dx * ab.dx + ab.dy * ab.dy;
      if (abLenSq <= 1e-6) continue;

      final ap = currentPose - a;
      final t = ((ap.dx * ab.dx) + (ap.dy * ab.dy)) / abLenSq;
      final clampedT = t.clamp(0.0, 1.0);
      final projection = Offset(
        a.dx + ab.dx * clampedT,
        a.dy + ab.dy * clampedT,
      );

      final dx = currentPose.dx - projection.dx;
      final dy = currentPose.dy - projection.dy;
      final distanceSq = dx * dx + dy * dy;

      if (distanceSq < bestDistanceSq) {
        bestDistanceSq = distanceSq;
        bestProjection = projection;
        bestSegmentIndex = i;
      }
    }

    return _PathProjection(
      projectedPoint: bestProjection,
      segmentIndex: bestSegmentIndex,
      distanceToPathPx: math.sqrt(bestDistanceSq),
    );
  }

  AudioCueDirection _computeOffRouteDirection({
    required double headingDeg,
    required Offset currentPoint,
    required Offset projectedPoint,
  }) {
    final correction = projectedPoint - currentPoint;
    if (correction.distance <= 1e-3) return AudioCueDirection.center;

    final theta = headingDeg * math.pi / 180.0;
    final forward = Offset(math.cos(theta), -math.sin(theta));
    final cross = (forward.dx * correction.dy) - (forward.dy * correction.dx);

    if (cross.abs() <= 1e-3) return AudioCueDirection.center;
    return cross < 0 ? AudioCueDirection.left : AudioCueDirection.right;
  }

  double _normalizedOffRouteSeverity(double distanceToPathPx) {
    const end = 240.0;
    final normalized = (distanceToPathPx - _offRouteThresholdPx) / (end - _offRouteThresholdPx);
    return normalized.clamp(0.0, 1.0);
  }
}

class _PathProjection {
  final Offset projectedPoint;
  final int segmentIndex;
  final double distanceToPathPx;

  const _PathProjection({
    required this.projectedPoint,
    required this.segmentIndex,
    required this.distanceToPathPx,
  });
}
