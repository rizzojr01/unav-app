import '../models/navigation_route.dart';
import '../models/navigation_session.dart';
import '../models/tracking_update.dart';

abstract class PathTracker {
  TrackingUpdate update({
    required NavigationSession session,
    required NavigationRoute route,
  });
}
