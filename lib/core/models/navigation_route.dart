import 'dart:ui';

import 'navigation_command.dart';
import 'route_segment.dart';

class NavigationRoute {
  final String floorKey;
  final List<Offset> points;
  final List<NavigationCommand> commands;

  const NavigationRoute({
    required this.floorKey,
    required this.points,
    required this.commands,
  });

  List<RouteSegment> get segments {
    if (points.length < 2) return const [];
    return List<RouteSegment>.generate(
      points.length - 1,
      (index) => RouteSegment(
        index: index,
        start: points[index],
        end: points[index + 1],
      ),
    );
  }
}
