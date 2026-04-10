import 'dart:async';
import 'dart:math' as math;

import '../../../core/interfaces/pose_provider.dart';
import '../../../core/models/localized_pose.dart';
import '../../../core/models/pose.dart';
import '../../../core/models/navigation_command.dart';
import '../../../core/models/navigation_session.dart';
import '../../../core/models/tracking_state.dart';
import '../domain/services/guidance_service.dart';
import '../domain/services/navigation_result_parser.dart';
import '../domain/services/path_tracking_service.dart';

class NavigationProcessingResult {
  final NavigationSession session;
  final bool shouldRefreshFloorplan;
  final List<String> speechTexts;

  const NavigationProcessingResult({
    required this.session,
    required this.shouldRefreshFloorplan,
    required this.speechTexts,
  });
}

class ArOverlaySnapshot {
  final List<math.Point<double>> activePathWorldPoints;
  final List<math.Point<double>> futurePathWorldPoints;
  final math.Point<double>? nextWaypointWorldPoint;
  final math.Point<double>? destinationWorldPoint;
  final double worldY;

  const ArOverlaySnapshot({
    required this.activePathWorldPoints,
    required this.futurePathWorldPoints,
    required this.nextWaypointWorldPoint,
    required this.destinationWorldPoint,
    required this.worldY,
  });
}

class NavigationController {
  static const double _overlayFloorOffsetMeters = 1.35;
  final NavigationResultParser _parser;
  final PathTrackingService _pathTracker;
  final GuidanceService _guidanceService;
  final PoseProvider? _poseProvider;

  NavigationSession _session = const NavigationSession();
  StreamSubscription<dynamic>? _poseSubscription;
  _ArTrackingAlignment? _arTrackingAlignment;
  String _languageCode = 'en';
  String _distanceUnit = 'meter';

  NavigationController({
    NavigationResultParser? parser,
    PathTrackingService? pathTracker,
    GuidanceService? guidanceService,
    PoseProvider? poseProvider,
  })  : _parser = parser ?? const NavigationResultParser(),
        _pathTracker = pathTracker ?? const PathTrackingService(),
        _guidanceService = guidanceService ?? const GuidanceService(),
        _poseProvider = poseProvider;

  NavigationSession get session => _session;
  double? get metersPerPixel => _arTrackingAlignment?.metersPerPixel;

  void configureArTrackingAlignment({
    required LocalizedPose referenceFloorplanPose,
    required double metersPerPixel,
    Pose? captureArPose,
  }) {
    _arTrackingAlignment = _ArTrackingAlignment(
      referenceFloorplanPose: referenceFloorplanPose,
      metersPerPixel: metersPerPixel <= 0 ? 1.0 : metersPerPixel,
      captureArPose: captureArPose,
    );
  }

  Future<void> startPoseTracking(void Function(NavigationSession session) onSessionUpdated) async {
    final poseProvider = _poseProvider;
    final route = _session.route;
    if (poseProvider == null || route == null) return;

    await _poseSubscription?.cancel();
    _poseSubscription = poseProvider.watchPose().listen((pose) {
      final localizedPose = _transformTrackedPose(
        pose: pose,
        routeFloorKey: route.floorKey,
      );

      final nextSession = _session.copyWith(
        currentPose: localizedPose,
        trackingState: TrackingState.tracking,
      );
      final trackingUpdate = _pathTracker.update(
        session: nextSession,
        route: route,
        metersPerPixel: _arTrackingAlignment?.metersPerPixel,
      );

      _session = nextSession.copyWith(
        trackedPath: trackingUpdate.trackedPath,
        currentSegmentIndex: trackingUpdate.currentSegmentIndex,
        nextWaypointIndex: trackingUpdate.nextWaypointIndex,
        remainingDistancePx: trackingUpdate.remainingDistancePx,
        distanceToNextWaypointPx: trackingUpdate.distanceToNextWaypointPx,
        distanceToPathPx: trackingUpdate.distanceToPathPx,
        offRouteSeverity: trackingUpdate.offRouteSeverity,
        offRouteDirection: trackingUpdate.offRouteDirection,
        trackingState: trackingUpdate.state,
        latestGuidanceEventType: trackingUpdate.events.isNotEmpty
            ? trackingUpdate.events.first.type
            : _session.latestGuidanceEventType,
        latestGuidanceMessage: trackingUpdate.events.isNotEmpty
            ? _buildTrackingInstruction(
                state: trackingUpdate.state,
                nextWaypointIndex: trackingUpdate.nextWaypointIndex,
                distanceToNextWaypointPx: trackingUpdate.distanceToNextWaypointPx,
              )
            : _session.latestGuidanceMessage,
      );
      onSessionUpdated(_session);
    });

    await poseProvider.start();
  }

  Future<void> stopPoseTracking() async {
    await _poseSubscription?.cancel();
    _poseSubscription = null;
    await _poseProvider?.stop();
  }

  Future<void> dispose() async {
    await stopPoseTracking();
  }

  NavigationProcessingResult processNavigationResult({
    required Map<String, dynamic> rawResult,
    required String languageCode,
    required String distanceUnit,
    required bool announceCurrentLocation,
    required bool playFullCommands,
  }) {
    _languageCode = languageCode;
    _distanceUnit = distanceUnit;
    final parsed = _parser.parse(rawResult);
    final shouldRefreshFloorplan = parsed.mapKey != _session.mapKey;
    final nextSession = _session.copyWith(
      route: parsed.route,
      mapKey: parsed.mapKey,
      rawResult: rawResult,
      currentPose: parsed.pose,
      localizedAnchorPose: parsed.pose,
      trackingState: parsed.pose == null ? TrackingState.localizing : TrackingState.tracking,
      clearLastSpokenSignature: shouldRefreshFloorplan,
    );

    final trackingUpdate = _pathTracker.update(
      session: nextSession,
      route: parsed.route,
      metersPerPixel: _arTrackingAlignment?.metersPerPixel,
    );

    final filteredCommands = _guidanceService.filterCommands(
      commands: parsed.route.commands,
      announceCurrentLocation: announceCurrentLocation,
    );
    final playbackCommands = _guidanceService.commandsForPlayback(
      commands: filteredCommands,
      playFullCommands: playFullCommands,
    );
    final speechTexts = _selectSpeechTexts(
      playbackCommands: playbackCommands,
      previousSignature: nextSession.lastSpokenSignature,
    );

    _session = nextSession.copyWith(
      trackedPath: trackingUpdate.trackedPath,
      currentSegmentIndex: trackingUpdate.currentSegmentIndex,
      nextWaypointIndex: trackingUpdate.nextWaypointIndex,
      remainingDistancePx: trackingUpdate.remainingDistancePx,
      distanceToNextWaypointPx: trackingUpdate.distanceToNextWaypointPx,
      distanceToPathPx: trackingUpdate.distanceToPathPx,
      offRouteSeverity: trackingUpdate.offRouteSeverity,
      offRouteDirection: trackingUpdate.offRouteDirection,
      trackingState: trackingUpdate.state,
      lastSpokenSignature: speechTexts.isEmpty
          ? nextSession.lastSpokenSignature
          : _guidanceService.buildSignature(playbackCommands),
      latestGuidanceEventType:
          trackingUpdate.events.isNotEmpty ? trackingUpdate.events.first.type : null,
      latestGuidanceMessage: trackingUpdate.events.isNotEmpty
          ? _buildTrackingInstruction(
              state: trackingUpdate.state,
              nextWaypointIndex: trackingUpdate.nextWaypointIndex,
              distanceToNextWaypointPx: trackingUpdate.distanceToNextWaypointPx,
            )
          : null,
    );

    return NavigationProcessingResult(
      session: _session,
      shouldRefreshFloorplan: shouldRefreshFloorplan,
      speechTexts: speechTexts,
    );
  }

  String buildPlaybackModeAnnouncement({
    required String languageCode,
    required bool playFullCommands,
  }) {
    return _guidanceService.buildPlaybackModeAnnouncement(
      languageCode: languageCode,
      playFullCommands: playFullCommands,
    );
  }

  String buildErrorMessage({
    required String languageCode,
    String? backendError,
  }) {
    return _guidanceService.buildErrorMessage(
      languageCode: languageCode,
      backendError: backendError,
    );
  }

  ArOverlaySnapshot? buildArOverlaySnapshot() {
    final alignment = _arTrackingAlignment;
    final route = _session.route;
    if (alignment == null || route == null || route.points.isEmpty) return null;

    final anchorPose = _session.localizedAnchorPose;
    final trackedPath = _session.trackedPath;
    final originArPose = alignment.originArPose;
    if (anchorPose == null || originArPose == null || trackedPath.isEmpty) return null;

    final pathWorldPoints = trackedPath
        .map(_floorplanPointToArWorld)
        .whereType<math.Point<double>>()
        .toList(growable: false);
    if (pathWorldPoints.isEmpty) return null;

    final activePathWorldPoints = pathWorldPoints.length >= 2
        ? pathWorldPoints.take(2).toList(growable: false)
        : pathWorldPoints;
    final futurePathWorldPoints = pathWorldPoints.length > 2
        ? pathWorldPoints.skip(1).toList(growable: false)
        : const <math.Point<double>>[];

    final nextWaypointIndex = _session.nextWaypointIndex.clamp(0, route.points.length - 1);
    final nextWaypointWorldPoint = _floorplanPointToArWorld(route.points[nextWaypointIndex]);
    final destinationWorldPoint = _floorplanPointToArWorld(route.points.last);
    final cameraWorldY = (originArPose.worldY as double?) ?? (originArPose.z as double?) ?? 0.0;
    final worldY = cameraWorldY - _overlayFloorOffsetMeters;

    return ArOverlaySnapshot(
      activePathWorldPoints: activePathWorldPoints,
      futurePathWorldPoints: futurePathWorldPoints,
      nextWaypointWorldPoint: nextWaypointWorldPoint,
      destinationWorldPoint: destinationWorldPoint,
      worldY: worldY,
    );
  }

  List<String> _selectSpeechTexts({
    required List<NavigationCommand> playbackCommands,
    required String? previousSignature,
  }) {
    final signature = _guidanceService.buildSignature(playbackCommands);
    if (signature.isEmpty || signature == previousSignature) return const [];
    return _guidanceService.textsFromCommands(playbackCommands);
  }

  String? _buildTrackingInstruction({
    required TrackingState state,
    required int nextWaypointIndex,
    required double distanceToNextWaypointPx,
  }) {
    if (state == TrackingState.offRoute) return null;
    if (state == TrackingState.arrived) {
      if (_languageCode == 'zh') return '已到达目的地。';
      if (_languageCode == 'th') return 'ถึงจุดหมายแล้ว';
      return 'Arrived at the destination.';
    }

    final route = _session.route;
    final pose = _session.currentPose;
    if (route == null || pose == null || route.points.isEmpty) return null;

    final waypoint = route.points[nextWaypointIndex.clamp(0, route.points.length - 1)];
    final dx = waypoint.dx - pose.x;
    final dy = waypoint.dy - pose.y;
    if (dx.abs() + dy.abs() <= 1e-3) return null;

    final bearingDeg = _normalizeDegrees(math.atan2(dy, dx) * 180.0 / math.pi);
    final headingDelta = _signedHeadingDeltaDeg(pose.heading, bearingDeg);
    final angle = headingDelta.abs().round();
    final metersPerPixel = _arTrackingAlignment?.metersPerPixel ?? 1.0;
    final distanceMeters = distanceToNextWaypointPx * metersPerPixel;
    final distanceText = _formatDistance(distanceMeters);

    if (angle <= 8) {
      if (_languageCode == 'zh') return '直行$distanceText。';
      if (_languageCode == 'th') return 'เดินตรง $distanceText';
      return 'Go straight for $distanceText.';
    }

    if (_languageCode == 'zh') {
      final dir = headingDelta > 0 ? '右转' : '左转';
      return '$dir$angle度，然后前进$distanceText。';
    }
    if (_languageCode == 'th') {
      final dir = headingDelta > 0 ? 'หมุนขวา' : 'หมุนซ้าย';
      return '$dir $angle องศา แล้วเดิน $distanceText';
    }
    final dir = headingDelta > 0 ? 'right' : 'left';
    return 'Turn $dir $angle degrees, then go $distanceText.';
  }

  String _formatDistance(double distanceMeters) {
    if (_distanceUnit == 'feet') {
      final feet = distanceMeters * 3.28084;
      return feet >= 10 ? '${feet.round()} feet' : '${feet.toStringAsFixed(1)} feet';
    }
    return distanceMeters >= 10
        ? '${distanceMeters.round()} meters'
        : '${distanceMeters.toStringAsFixed(1)} meters';
  }

  LocalizedPose _transformTrackedPose({
    required dynamic pose,
    required String routeFloorKey,
  }) {
    final alignment = _arTrackingAlignment;
    if (alignment == null) {
      final floorKey = _session.mapKey ?? routeFloorKey;
      return LocalizedPose(
        floorKey: floorKey,
        x: pose.x,
        y: pose.y,
        z: pose.z,
        heading: pose.heading,
        confidence: pose.confidence,
        timestamp: pose.timestamp,
      );
    }

    // Use the ARKit pose captured at photo time (not the first streaming
    // pose after the server responds). This eliminates heading drift when
    // the user rotates between capture and server response.
    alignment.originArPose ??= alignment.captureArPose ?? pose;
    final origin = alignment.originArPose!;
    final reference = alignment.referenceFloorplanPose;
    final originArPoint = _extractArPlanarPoint(origin);
    final currentArPoint = _extractArPlanarPoint(pose);
    final arDeltaX = currentArPoint.x - originArPoint.x;
    final arDeltaY = currentArPoint.y - originArPoint.y;
    final captureHeading = _captureHeadingDegrees(origin);
    final currentHeading = _captureHeadingDegrees(pose);
    final sumHeadingDeg = _normalizeDegrees(reference.heading + captureHeading);
    final sumHeadingRad = sumHeadingDeg * math.pi / 180.0;

    final rotatedX =
        (arDeltaX * math.cos(sumHeadingRad)) + (arDeltaY * math.sin(sumHeadingRad));
    final rotatedY =
        (arDeltaY * math.cos(sumHeadingRad)) - (arDeltaX * math.sin(sumHeadingRad));

    final deltaFloorplanMath = math.Point<double>(
      rotatedX / alignment.metersPerPixel,
      rotatedY / alignment.metersPerPixel,
    );
    final referenceFloorplanMath = _imagePointToMathPlane(
      math.Point<double>(reference.x, reference.y),
    );
    final currentFloorplanMath = math.Point<double>(
      referenceFloorplanMath.x + deltaFloorplanMath.x,
      referenceFloorplanMath.y + deltaFloorplanMath.y,
    );
    final currentFloorplanImage = _mathPlaneToImagePoint(currentFloorplanMath);

    return LocalizedPose(
      floorKey: reference.floorKey,
      x: currentFloorplanImage.x,
      y: currentFloorplanImage.y,
      z: pose.z,
      heading: _normalizeDegrees(sumHeadingDeg - currentHeading),
      confidence: pose.confidence,
      timestamp: pose.timestamp,
    );
  }

  math.Point<double> _extractArPlanarPoint(dynamic pose) {
    final worldX = (pose.worldX as double?) ?? pose.x as double;
    final worldZ = (pose.worldZ as double?) ?? -(pose.y as double);
    return math.Point<double>(worldX, -worldZ);
  }

  double _captureHeadingDegrees(dynamic pose) {
    return _normalizeDegrees(pose.heading as double);
  }

  math.Point<double>? _floorplanPointToArWorld(dynamic floorplanPoint) {
    final alignment = _arTrackingAlignment;
    if (alignment == null || alignment.originArPose == null) return null;

    final reference = alignment.referenceFloorplanPose;
    final origin = alignment.originArPose!;
    final originArPoint = _extractArPlanarPoint(origin);
    final captureHeading = _captureHeadingDegrees(origin);
    final sumHeadingDeg = _normalizeDegrees(reference.heading + captureHeading);
    final sumHeadingRad = sumHeadingDeg * math.pi / 180.0;

    final targetFloorplanMath = _imagePointToMathPlane(
      math.Point<double>(floorplanPoint.dx as double, floorplanPoint.dy as double),
    );
    final referenceFloorplanMath = _imagePointToMathPlane(
      math.Point<double>(reference.x, reference.y),
    );

    final deltaMeters = math.Point<double>(
      (targetFloorplanMath.x - referenceFloorplanMath.x) * alignment.metersPerPixel,
      (targetFloorplanMath.y - referenceFloorplanMath.y) * alignment.metersPerPixel,
    );

    final arDeltaX =
        (deltaMeters.x * math.cos(sumHeadingRad)) - (deltaMeters.y * math.sin(sumHeadingRad));
    final arDeltaY =
        (deltaMeters.x * math.sin(sumHeadingRad)) + (deltaMeters.y * math.cos(sumHeadingRad));

    final targetArPlanar = math.Point<double>(
      originArPoint.x + arDeltaX,
      originArPoint.y + arDeltaY,
    );

    return math.Point<double>(targetArPlanar.x, -targetArPlanar.y);
  }

  math.Point<double> _imagePointToMathPlane(math.Point<double> point) {
    return math.Point<double>(point.x, -point.y);
  }

  math.Point<double> _mathPlaneToImagePoint(math.Point<double> point) {
    return math.Point<double>(point.x, -point.y);
  }

  double _normalizeDegrees(double value) {
    var normalized = value % 360.0;
    if (normalized < 0) {
      normalized += 360.0;
    }
    return normalized;
  }

  double _signedHeadingDeltaDeg(double currentDeg, double targetDeg) {
    var delta = (targetDeg - currentDeg + 540.0) % 360.0 - 180.0;
    if (delta < -180.0) {
      delta += 360.0;
    }
    return delta;
  }
}

class _ArTrackingAlignment {
  final LocalizedPose referenceFloorplanPose;
  final double metersPerPixel;
  /// ARKit pose at photo-capture time. Used to initialize [originArPose]
  /// so that the rotation matrix is anchored to the moment the query image
  /// was taken, not the moment the server response arrives.
  final Pose? captureArPose;
  dynamic originArPose;

  _ArTrackingAlignment({
    required this.referenceFloorplanPose,
    required this.metersPerPixel,
    this.captureArPose,
  });
}
