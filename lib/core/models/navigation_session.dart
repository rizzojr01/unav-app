import 'dart:ui';

import 'audio_cue_direction.dart';
import 'guidance_event.dart';
import 'localized_pose.dart';
import 'navigation_route.dart';
import 'tracking_state.dart';

class NavigationSession {
  final NavigationRoute? route;
  final String? mapKey;
  final Map<String, dynamic>? rawResult;
  final LocalizedPose? currentPose;
  final LocalizedPose? localizedAnchorPose;
  final List<Offset> trackedPath;
  final int currentSegmentIndex;
  final int nextWaypointIndex;
  final double remainingDistancePx;
  final double distanceToNextWaypointPx;
  final double distanceToPathPx;
  final double offRouteSeverity;
  final AudioCueDirection offRouteDirection;
  final TrackingState trackingState;
  final String? lastSpokenSignature;
  final String? latestGuidanceMessage;
  final GuidanceEventType? latestGuidanceEventType;

  const NavigationSession({
    this.route,
    this.mapKey,
    this.rawResult,
    this.currentPose,
    this.localizedAnchorPose,
    this.trackedPath = const [],
    this.currentSegmentIndex = 0,
    this.nextWaypointIndex = 0,
    this.remainingDistancePx = 0,
    this.distanceToNextWaypointPx = 0,
    this.distanceToPathPx = 0,
    this.offRouteSeverity = 0,
    this.offRouteDirection = AudioCueDirection.center,
    this.trackingState = TrackingState.idle,
    this.lastSpokenSignature,
    this.latestGuidanceMessage,
    this.latestGuidanceEventType,
  });

  NavigationSession copyWith({
    NavigationRoute? route,
    String? mapKey,
    Map<String, dynamic>? rawResult,
    LocalizedPose? currentPose,
    LocalizedPose? localizedAnchorPose,
    List<Offset>? trackedPath,
    int? currentSegmentIndex,
    int? nextWaypointIndex,
    double? remainingDistancePx,
    double? distanceToNextWaypointPx,
    double? distanceToPathPx,
    double? offRouteSeverity,
    AudioCueDirection? offRouteDirection,
    TrackingState? trackingState,
    String? lastSpokenSignature,
    String? latestGuidanceMessage,
    GuidanceEventType? latestGuidanceEventType,
    bool clearLastSpokenSignature = false,
  }) {
    return NavigationSession(
      route: route ?? this.route,
      mapKey: mapKey ?? this.mapKey,
      rawResult: rawResult ?? this.rawResult,
      currentPose: currentPose ?? this.currentPose,
      localizedAnchorPose: localizedAnchorPose ?? this.localizedAnchorPose,
      trackedPath: trackedPath ?? this.trackedPath,
      currentSegmentIndex: currentSegmentIndex ?? this.currentSegmentIndex,
      nextWaypointIndex: nextWaypointIndex ?? this.nextWaypointIndex,
      remainingDistancePx: remainingDistancePx ?? this.remainingDistancePx,
      distanceToNextWaypointPx:
          distanceToNextWaypointPx ?? this.distanceToNextWaypointPx,
      distanceToPathPx: distanceToPathPx ?? this.distanceToPathPx,
      offRouteSeverity: offRouteSeverity ?? this.offRouteSeverity,
      offRouteDirection: offRouteDirection ?? this.offRouteDirection,
      trackingState: trackingState ?? this.trackingState,
      lastSpokenSignature: clearLastSpokenSignature
          ? null
          : (lastSpokenSignature ?? this.lastSpokenSignature),
      latestGuidanceMessage: latestGuidanceMessage ?? this.latestGuidanceMessage,
      latestGuidanceEventType: latestGuidanceEventType ?? this.latestGuidanceEventType,
    );
  }
}
