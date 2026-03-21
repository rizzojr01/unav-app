enum GuidanceEventType {
  trackingUpdated,
  waypointAdvanced,
  waypointRegressed,
  approachingWaypoint,
  turnNow,
  offRoute,
  arrived,
}

class GuidanceEvent {
  final GuidanceEventType type;
  final String message;

  const GuidanceEvent({
    required this.type,
    required this.message,
  });
}
