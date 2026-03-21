import 'dart:async';
import 'dart:math' as math;

import '../../../../core/interfaces/pose_provider.dart';
import '../../../../core/models/pose.dart';
import '../../../../core/models/navigation_route.dart';

class MockRoutePoseProvider implements PoseProvider {
  final Duration interval;
  final double pixelsPerTick;

  final StreamController<Pose> _controller = StreamController<Pose>.broadcast();
  Timer? _timer;
  NavigationRoute? _route;
  int _segmentIndex = 0;
  double _distanceAlongSegment = 0;
  bool _running = false;

  MockRoutePoseProvider({
    this.interval = const Duration(milliseconds: 500),
    this.pixelsPerTick = 28,
  });

  void loadRoute(NavigationRoute route) {
    _route = route;
    _segmentIndex = 0;
    _distanceAlongSegment = 0;
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(interval, (_) => _emitNextPose());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  Stream<Pose> watchPose() => _controller.stream;

  void _emitNextPose() {
    final route = _route;
    if (!_running || route == null || route.points.length < 2) return;

    if (_segmentIndex >= route.points.length - 1) {
      final last = route.points.last;
      _controller.add(
        Pose(
          x: last.dx,
          y: last.dy,
          heading: 0,
          timestamp: DateTime.now(),
        ),
      );
      stop();
      return;
    }

    final start = route.points[_segmentIndex];
    final end = route.points[_segmentIndex + 1];
    final delta = end - start;
    final segmentLength = delta.distance;

    if (segmentLength <= 1e-6) {
      _segmentIndex++;
      _distanceAlongSegment = 0;
      return;
    }

    _distanceAlongSegment += pixelsPerTick;
    while (_distanceAlongSegment >= segmentLength &&
        _segmentIndex < route.points.length - 1) {
      _distanceAlongSegment -= segmentLength;
      _segmentIndex++;
      if (_segmentIndex >= route.points.length - 1) break;
    }

    if (_segmentIndex >= route.points.length - 1) {
      final last = route.points.last;
      _controller.add(
        Pose(
          x: last.dx,
          y: last.dy,
          heading: 0,
          timestamp: DateTime.now(),
        ),
      );
      stop();
      return;
    }

    final segStart = route.points[_segmentIndex];
    final segEnd = route.points[_segmentIndex + 1];
    final segDelta = segEnd - segStart;
    final segLength = segDelta.distance;
    final t = segLength <= 1e-6 ? 0.0 : (_distanceAlongSegment / segLength).clamp(0.0, 1.0);
    final heading = math.atan2(segDelta.dy, segDelta.dx) * 180 / math.pi;

    _controller.add(
      Pose(
        x: segStart.dx + segDelta.dx * t,
        y: segStart.dy + segDelta.dy * t,
        heading: heading,
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
