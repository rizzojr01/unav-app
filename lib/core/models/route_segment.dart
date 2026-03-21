import 'dart:ui';

class RouteSegment {
  final int index;
  final Offset start;
  final Offset end;

  const RouteSegment({
    required this.index,
    required this.start,
    required this.end,
  });

  double get length => (end - start).distance;
}
