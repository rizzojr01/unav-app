import 'dart:async';
import 'dart:math' as math;

import '../../../core/interfaces/pose_provider.dart';
import '../../../core/models/localized_pose.dart';
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

class NavigationController {
  final NavigationResultParser _parser;
  final PathTrackingService _pathTracker;
  final GuidanceService _guidanceService;
  final PoseProvider? _poseProvider;

  NavigationSession _session = const NavigationSession();
  StreamSubscription<dynamic>? _poseSubscription;
  _ArTrackingAlignment? _arTrackingAlignment;

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

  void configureArTrackingAlignment({
    required LocalizedPose referenceFloorplanPose,
    required double metersPerPixel,
  }) {
    _arTrackingAlignment = _ArTrackingAlignment(
      referenceFloorplanPose: referenceFloorplanPose,
      metersPerPixel: metersPerPixel <= 0 ? 1.0 : metersPerPixel,
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
            ? trackingUpdate.events.first.message
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
    required bool announceCurrentLocation,
    required bool playFullCommands,
  }) {
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
      latestGuidanceMessage:
          trackingUpdate.events.isNotEmpty ? trackingUpdate.events.first.message : null,
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

  List<String> _selectSpeechTexts({
    required List<NavigationCommand> playbackCommands,
    required String? previousSignature,
  }) {
    final signature = _guidanceService.buildSignature(playbackCommands);
    if (signature.isEmpty || signature == previousSignature) return const [];
    return _guidanceService.textsFromCommands(playbackCommands);
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

    alignment.originArPose ??= pose;
    final origin = alignment.originArPose!;
    final reference = alignment.referenceFloorplanPose;
    final originArPoint = _extractArPlanarPoint(origin);
    final currentArPoint = _extractArPlanarPoint(pose);
    final arDeltaX = currentArPoint.x - originArPoint.x;
    final arDeltaY = currentArPoint.y - originArPoint.y;
    final captureHeading = _captureHeadingDegrees(origin);
    final currentHeading = _captureHeadingDegrees(pose);
    final rotationDeg = _normalizeDegrees(reference.heading - captureHeading);
    final rotationRad = rotationDeg * math.pi / 180.0;

    final rotatedX =
        (arDeltaX * math.cos(rotationRad)) - (arDeltaY * math.sin(rotationRad));
    final rotatedY =
        (arDeltaX * math.sin(rotationRad)) + (arDeltaY * math.cos(rotationRad));

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
      heading: _normalizeDegrees(currentHeading + rotationDeg),
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
}

class _ArTrackingAlignment {
  final LocalizedPose referenceFloorplanPose;
  final double metersPerPixel;
  dynamic originArPose;

  _ArTrackingAlignment({
    required this.referenceFloorplanPose,
    required this.metersPerPixel,
  });
}
