// lib/screens/navigation_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart'; // HapticFeedback + rootBundle
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:audioplayers/audioplayers.dart';

import '../api/api_service.dart';
import '../core/models/audio_cue_direction.dart';
import '../core/models/guidance_event.dart';
import '../core/models/navigation_session.dart';
import '../core/models/tracking_state.dart';
import '../features/navigation/application/navigation_controller.dart';
import '../features/navigation/domain/services/guidance_sound_service.dart';
import '../features/navigation/infrastructure/tracking/ar_channel_contract.dart';
import '../features/navigation/infrastructure/tracking/native_ar_session_adapter.dart';
import '../features/navigation/infrastructure/tracking/pose_provider_factory.dart';
import '../features/navigation/presentation/widgets/guidance_banner.dart';
import '../widgets/floorplan_path_painter.dart';
import '../services/trial_recorder.dart';
import '../services/tts_service.dart';
import '../providers/settings_provider.dart';

const Map<String, List<String>> turnKeywords = {
  'en': [
    'turn',
    'slight left',
    'slight right',
    'sharp right',
    'sharp left',
    'u-turn',
  ],
  'zh': ['转弯', '掉头'],
  'th': ['เลี้ยว', 'กลับรถ'],
};

const Map<String, List<String>> forwardKeywords = {
  'en': ['forward'],
  'zh': ['直行'],
  'th': ['เดินตรงไป'],
};

class NavigationScreen extends StatefulWidget {
  final String selectedPlaceId;
  final String selectedPlaceName;
  final String selectedBuildingId;
  final String selectedBuildingName;
  final String selectedFloorId;
  final String selectedFloorName;
  final String selectedDestinationId;
  final String selectedDestinationName;

  const NavigationScreen({
    super.key,
    required this.selectedPlaceId,
    required this.selectedPlaceName,
    required this.selectedBuildingId,
    required this.selectedBuildingName,
    required this.selectedFloorId,
    required this.selectedFloorName,
    required this.selectedDestinationId,
    required this.selectedDestinationName,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with WidgetsBindingObserver {
  static const double _headingLockThresholdDeg = 8.0;
  static const double _spatialCueDistanceMeters = 6.0;
  static const bool _enableSpatialAudioExperiment = true;
  static const bool _enableDirectionalDrumStartupTest = false;

  // ---- Floorplan / path rendering state ----
  Uint8List? _floorplanBytes;
  ui.Image? _decodedFloorplanImage;
  List<Offset> _currentPath = [];
  final PoseProviderFactory _poseProviderFactory = const PoseProviderFactory();
  late final PoseProviderBundle _poseProviderBundle;
  late final NavigationController _navigationController;
  late final GuidanceSoundService _guidanceSoundService;
  Timer? _speechDebounceTimer;
  String? _lastGuidanceCueSignature;
  String? _lastSpokenTrackingMessage;
  String? _lastSpokenTrackingEventSignature;
  int? _lastDistanceAnnouncedWaypointIndex;
  int? _lastDistanceCountdownMark;
  bool? _lastHeadingAligned;
  bool _spatialAudioExperimentEnabled = _enableSpatialAudioExperiment;
  bool _spatialAudioExperimentActivated = false;
  AudioOutputStatus _audioOutputStatus = const AudioOutputStatus.unknown();
  DateTime? _lastAudioRouteCheckAt;

  // ---- Camera state ----
  CameraController? _cameraController;
  final MethodChannel _arMethodChannel = const MethodChannel(
    ArChannelContract.methodChannel,
  );
  bool _isCameraInitialized = false;
  bool _isLoading = false;
  bool _isRebuildingCamera = false;
  int _cameraPreviewVersion = 0;

  // ---- UI mode ----
  bool _firstPerson = false;

  // ---- TTS play mode ----
  // false: speak only the "current step group"
  // true : speak all cmds (full route playback)
  bool _playFullCommands = false;

  // ---- Low-latency UI sound (audioplayers) ----
  late final AudioPlayer _playerSend;

  bool get _usesNativeArPreview =>
      (Platform.isIOS || Platform.isAndroid) &&
      _poseProviderBundle.mode == PoseProviderMode.nativeAr;

  String get _nativeArBackendName =>
      Platform.isAndroid ? 'androidArCore' : 'iosArKit';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poseProviderBundle = _poseProviderFactory.create(
      preferredMode: PoseProviderMode.nativeAr,
    );
    _navigationController = NavigationController(
      poseProvider: _poseProviderBundle.provider,
    );
    _guidanceSoundService = GuidanceSoundService(
      preferredMode: _enableSpatialAudioExperiment && Platform.isIOS
          ? GuidanceAudioMode.auto
          : GuidanceAudioMode.stereo,
    );

    _configureAudioForUiSounds(); // set audio context
    _initUiSoundPlayer(); // prepare player + preload asset
    unawaited(_initializeGuidanceAudio());

    _fetchFloorplan();
    if (_usesNativeArPreview) {
      unawaited(_ensureArPreviewSessionStarted());
    } else {
      _initCamera();
    }

    // Start a research trial if the platform supports native AR tracking.
    // Everything runs in parallel with normal navigation — we piggyback on
    // the existing ARKit stream and per-capture hook to persist data for
    // offline drift analysis.
    unawaited(_startTrialIfSupported());
  }

  @override
  void dispose() {
    // Finalize any in-flight research trial before tearing down providers.
    // This is fire-and-forget: the recorder persists everything to disk
    // synchronously, and the zip upload happens in the background.
    unawaited(TrialRecorder.instance.endTrial(TrialEndReason.cancelled));
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _speechDebounceTimer?.cancel();
    _navigationController.dispose();
    _poseProviderBundle.dispose();
    _guidanceSoundService.dispose();
    _playerSend.dispose();
    super.dispose();
  }

  /// Start a [TrialRecorder] session for the duration of this navigation
  /// screen. Silently no-ops on backends without a real ARKit adapter.
  Future<void> _startTrialIfSupported() async {
    final adapter = _poseProviderBundle.arSessionAdapter;
    if (adapter is! NativeArSessionAdapter) return;
    try {
      await TrialRecorder.instance.startTrial(
        context: TrialContext(
          placeId: widget.selectedPlaceId,
          placeName: widget.selectedPlaceName,
          buildingId: widget.selectedBuildingId,
          buildingName: widget.selectedBuildingName,
          floorId: widget.selectedFloorId,
          floorName: widget.selectedFloorName,
          destinationId: widget.selectedDestinationId,
          destinationName: widget.selectedDestinationName,
        ),
        poseStream: _poseProviderBundle.provider.watchPose(),
        adapter: adapter,
      );
    } catch (_) {
      // Research logging is best-effort; never break navigation.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_usesNativeArPreview) {
      if (state == AppLifecycleState.resumed) {
        unawaited(_ensureArPreviewSessionStarted());
        unawaited(_refreshAudioOutputStatus());
      }
      return;
    }
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
      unawaited(_refreshAudioOutputStatus());
    }
  }

  Future<void> _initializeGuidanceAudio() async {
    await _guidanceSoundService.init();
    await _guidanceSoundService.primeDirectionalGuidance();
    await _refreshAudioOutputStatus();
    if (_enableDirectionalDrumStartupTest) {
      _guidanceSoundService.updateDirectionalGuidance(
        isActive: true,
        severity: 1.0,
        direction: AudioCueDirection.left,
        headingErrorDeg: 90,
        relativeAngleDeg: 45,
        sourceDistanceMeters: _spatialCueDistanceMeters,
        distanceToWaypointMeters: 2.0,
      );
    }
  }

  Future<void> _refreshAudioOutputStatus() async {
    final status = await _guidanceSoundService.getAudioOutputStatus();
    if (!mounted) return;
    setState(() {
      _audioOutputStatus = status;
    });
  }

  /// Configure audio context for short UI sounds (Android/iOS)
  Future<void> _configureAudioForUiSounds() async {
    try {
      await AudioPlayer.global.setAudioContext(
        const AudioContext(
          android: AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.assistanceSonification,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            isSpeakerphoneOn: true,
            stayAwake: false,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: [
              AVAudioSessionOptions.mixWithOthers,
              AVAudioSessionOptions.allowBluetooth,
              AVAudioSessionOptions.defaultToSpeaker,
            ],
          ),
        ),
      );
    } catch (_) {}
  }

  /// Prepare a low-latency player and preload the asset.
  Future<void> _initUiSoundPlayer() async {
    _playerSend = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    try {
      await _playerSend.setPlayerMode(PlayerMode.lowLatency);
      await _playerSend.setVolume(1.0);
    } catch (_) {}
  }

  // ========================= Camera & Floorplan =========================

  Future<void> _fetchFloorplan() async {
    try {
      final fp = await ApiService.getFloorplan();
      if (fp != null) {
        decodeImageFromList(fp).then((ui.Image img) {
          if (!mounted) return;
          setState(() {
            _floorplanBytes = fp;
            _decodedFloorplanImage = img;
          });
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _floorplanBytes = null;
        _decodedFloorplanImage = null;
      });
    }
  }

  Future<void> _initCamera() async {
    if (_usesNativeArPreview) return;
    if (_isRebuildingCamera) return;
    _isRebuildingCamera = true;
    try {
      final previousController = _cameraController;
      if (mounted) {
        setState(() {
          _cameraController = null;
          _isCameraInitialized = false;
          _cameraPreviewVersion++;
        });
      }
      await previousController?.dispose();

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _isCameraInitialized = false);
        return;
      }
      final controller = CameraController(
        cameras[0],
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _cameraController = controller;
        _isCameraInitialized = true;
        _cameraPreviewVersion++;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraController = null;
        _isCameraInitialized = false;
      });
    } finally {
      _isRebuildingCamera = false;
    }
  }

  // ========================= Capture & Send =========================

  void _onTapCapture() {
    _captureAndSend();
  }

  Future<void> _ensureArPreviewSessionStarted() async {
    try {
      await _arMethodChannel.invokeMethod<void>(
        ArChannelContract.startSessionMethod,
        {ArChannelContract.backendKey: _nativeArBackendName},
      );
    } catch (_) {}
  }

  Future<Uint8List?> _capturePreviewFrameBytes() async {
    if (_usesNativeArPreview) {
      await _ensureArPreviewSessionStarted();
      final bytes = await _arMethodChannel.invokeMethod<Uint8List>(
        ArChannelContract.captureCurrentFrameMethod,
        {ArChannelContract.backendKey: _nativeArBackendName},
      );
      if (bytes == null || bytes.isEmpty) return null;
      return fixImageOrientation(bytes);
    }

    if (!_isCameraInitialized || _cameraController == null) return null;
    var controller = _cameraController!;
    if (controller.value.isPreviewPaused) {
      await _initCamera();
      if (_cameraController == null) return null;
      controller = _cameraController!;
    }

    final file = await controller.takePicture();
    final rawBytes = await file.readAsBytes();
    return fixImageOrientation(rawBytes);
  }

  /// Play a short local audio + haptic when sending begins.
  Future<void> _playSendCue() async {
    try {
      await _playerSend.play(
        AssetSource('sounds/send.wav'),
        mode: PlayerMode.lowLatency,
        volume: 1.0,
      );
      await HapticFeedback.mediumImpact();
      await HapticFeedback.vibrate();
    } catch (_) {}
  }

  Future<void> _captureAndSend() async {
    if (_isLoading) return;
    if (!_usesNativeArPreview &&
        (!_isCameraInitialized || _cameraController == null))
      return;
    setState(() => _isLoading = true);

    // 1) Play cue first
    await _playSendCue();

    // 2) Delay a bit to avoid focus race with camera shutter
    await Future.delayed(
      const Duration(milliseconds: 150),
    ); // 150ms for extra safety

    try {
      // When native AR preview is in use, capture the frame *with its
      // contemporaneous ARKit pose and arTimestamp* so TrialRecorder can
      // index the query against the pose stream. The existing capture path
      // is kept intact for non-native backends (e.g. mock route / stub).
      Uint8List? fixedBytes;
      NativeCaptureResult? nativeCapture;
      if (_usesNativeArPreview) {
        final adapter = _poseProviderBundle.arSessionAdapter;
        if (adapter is NativeArSessionAdapter) {
          try {
            await _ensureArPreviewSessionStarted();
            nativeCapture = await adapter.captureWithPose();
          } catch (_) {
            nativeCapture = null;
          }
          if (nativeCapture != null) {
            fixedBytes = await fixImageOrientation(nativeCapture.jpegBytes);
          }
        }
      }
      // Fallback: legacy capture path (camera plugin or old native call).
      fixedBytes ??= await _capturePreviewFrameBytes();
      if (fixedBytes == null) {
        await _handleError(null);
        return;
      }
      final result = await ApiService.unavNavigation(fixedBytes, 'query.jpg');
      if (!mounted) return;

      // Persist this VPR query into the active TrialRecorder session.
      // Best-effort: any failure in the recorder path is swallowed and the
      // user-facing navigation result is unaffected.
      if (nativeCapture != null && TrialRecorder.instance.isActive) {
        unawaited(
          TrialRecorder.instance.recordQuery(
            capture: nativeCapture,
            serverResponse: result,
          ),
        );
      }

      if (result['success'] == true) {
        await _processNavResult(result);
      } else {
        await _handleError(result['error']?.toString() ?? 'Unknown error');
        return;
      }
    } catch (_) {
      await _handleError(null);
    } finally {
      if (mounted) setState(() => _isLoading = false);
      if (!_usesNativeArPreview) {
        unawaited(_rebuildLiveCameraPreview());
      }
    }
  }

  Future<void> _rebuildLiveCameraPreview() async {
    await _initCamera();
  }

  Future<Uint8List> fixImageOrientation(Uint8List imageBytes) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    const maxSide = 640;
    final bool landscape = w >= h;
    final int newW = landscape ? maxSide : (w * maxSide / h).round();
    final int newH = landscape ? (h * maxSide / w).round() : maxSide;

    return FlutterImageCompress.compressWithList(
      imageBytes,
      format: CompressFormat.jpeg,
      quality: 99,
      minWidth: newW,
      minHeight: newH,
      autoCorrectionAngle: true,
    );
  }

  // ========================= Result Handling & TTS =========================

  Future<void> _processNavResult(Map<String, dynamic> result) async {
    final provider = context.read<SettingsProvider>();
    final processingResult = _navigationController.processNavigationResult(
      rawResult: result,
      languageCode: provider.languageCode,
      distanceUnit: provider.unit,
      announceCurrentLocation: provider.announceCurrentLocation,
      playFullCommands: _playFullCommands,
    );

    if (processingResult.shouldRefreshFloorplan) {
      await _fetchFloorplan();
    }

    if (processingResult.speechTexts.isNotEmpty) {
      await TTSService.setLanguage(provider.languageCode);
      TTSService.speakSequentially(processingResult.speechTexts);
    }

    _lastDistanceAnnouncedWaypointIndex = null;
    _lastDistanceCountdownMark = null;
    setState(() {
      _currentPath = processingResult.session.trackedPath;
    });
    _maybeSpeakDistanceAnnouncement(processingResult.session);
    _playGuidanceCueIfNeeded(processingResult.session);
    unawaited(_syncArOverlay(processingResult.session));

    final route = processingResult.session.route;
    if (route != null && route.points.length > 1) {
      final referencePose = processingResult.session.currentPose;
      final floorScale = await ApiService.getCurrentFloorScale();
      if (referencePose != null && floorScale != null) {
        final metersPerPixel = provider.unit == 'feet'
            ? floorScale * 0.3048
            : floorScale;
        _navigationController.configureArTrackingAlignment(
          referenceFloorplanPose: referencePose,
          metersPerPixel: metersPerPixel,
        );
      }
      final mockRouteProvider = _poseProviderBundle.mockRouteProvider;
      mockRouteProvider?.loadRoute(route);
      try {
        await _navigationController.startPoseTracking(
          _handleTrackingSessionUpdated,
        );
      } catch (_) {
        await _handleError(
          provider.languageCode == 'zh'
              ? 'AR 跟踪当前不可用，请检查设备是否支持。'
              : provider.languageCode == 'th'
              ? 'การติดตาม AR ยังไม่พร้อมใช้งานบนอุปกรณ์นี้'
              : 'AR tracking is unavailable on this device.',
        );
      }
    }
  }

  void _handleTrackingSessionUpdated(NavigationSession session) {
    if (!mounted) return;
    setState(() {
      _currentPath = session.trackedPath;
    });

    final now = DateTime.now();
    if (_lastAudioRouteCheckAt == null ||
        now.difference(_lastAudioRouteCheckAt!) >= const Duration(seconds: 1)) {
      _lastAudioRouteCheckAt = now;
      unawaited(_reconcileAudioOutputRouting(session));
    }

    if (!_spatialAudioExperimentActivated) {
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        unawaited(_maybeActivateSpatialAudioForSession(_navigationController.session));
      });
    }
    _maybeSpeakDistanceAnnouncement(session);
    _playGuidanceCueIfNeeded(session);
    unawaited(_syncArOverlay(session));

    final eventType = session.latestGuidanceEventType;
    if (eventType == GuidanceEventType.offRoute || eventType == null) {
      return;
    }

    final shouldSpeakForEvent =
        eventType == GuidanceEventType.waypointAdvanced ||
        eventType == GuidanceEventType.arrived;
    if (!shouldSpeakForEvent) {
      return;
    }

    // Finalize the research trial with the correct end reason when the
    // user arrives at their destination. dispose() will still end the
    // trial as `cancelled` if we leave without arriving.
    if (eventType == GuidanceEventType.arrived &&
        TrialRecorder.instance.isActive) {
      unawaited(TrialRecorder.instance.endTrial(TrialEndReason.arrived));
    }

    final msg = session.latestGuidanceMessage;
    if (msg == null || msg.isEmpty) return;
    final eventSignature =
        '${eventType.name}:${session.nextWaypointIndex}:${session.currentSegmentIndex}';
    if (_lastSpokenTrackingEventSignature == eventSignature &&
        _lastSpokenTrackingMessage == msg) {
      return;
    }
    _lastSpokenTrackingEventSignature = eventSignature;
    _lastSpokenTrackingMessage = msg;
    _speechDebounceTimer?.cancel();
    _speechDebounceTimer = Timer(const Duration(milliseconds: 50), () async {
      await TTSService.setLanguage(
        context.read<SettingsProvider>().languageCode,
      );
      await TTSService.speak(msg);
    });
  }

  void _maybeSpeakDistanceAnnouncement(NavigationSession session) {
    if (session.trackingState == TrackingState.arrived ||
        session.trackingState == TrackingState.offRoute) {
      return;
    }
    final route = session.route;
    if (route == null || route.points.isEmpty) return;
    final waypointIndex = session.nextWaypointIndex.clamp(0, route.points.length - 1);
    if (_lastDistanceAnnouncedWaypointIndex != waypointIndex) {
      _lastDistanceAnnouncedWaypointIndex = waypointIndex;
      _lastDistanceCountdownMark = null;
    }

    final distanceMeters = _distanceToNextWaypointMeters(session);
    if (distanceMeters > 5.0) {
      _lastDistanceCountdownMark = null;
      return;
    }

    final countdownMark = _nextDistanceCountdownMark(distanceMeters);
    if (countdownMark == null || countdownMark == _lastDistanceCountdownMark) {
      return;
    }

    final msg = _buildDistanceAnnouncement(
      distanceMeters,
      countdownMark: countdownMark,
    );
    if (msg == null || msg.isEmpty) return;
    _lastDistanceCountdownMark = countdownMark;
    _speechDebounceTimer?.cancel();
    _speechDebounceTimer = Timer(const Duration(milliseconds: 50), () async {
      await TTSService.setLanguage(
        context.read<SettingsProvider>().languageCode,
      );
      await TTSService.speak(msg);
    });
  }

  void _playGuidanceCueIfNeeded(NavigationSession session) {
    final headingErrorDeg = _headingErrorToNextWaypoint(session);
    final relativeAngleDeg = _signedHeadingDeltaToNextWaypoint(session);
    final headingDirection = _headingCueDirectionToNextWaypoint(session);
    final headingAligned = headingErrorDeg <= _headingLockThresholdDeg;
    _emitHeadingLatchHapticIfNeeded(headingAligned);

    final hasNextWaypointTarget = session.trackedPath.length >= 2;
    final isDirectionalGuidanceActive =
        hasNextWaypointTarget && session.trackingState != TrackingState.arrived;
    final guidanceSeverity = session.trackingState == TrackingState.offRoute
        ? session.offRouteSeverity.clamp(0.35, 1.0)
        : _normalizedHeadingSeverity(headingErrorDeg);
    final guidanceDirection = session.trackingState == TrackingState.offRoute
        ? session.offRouteDirection
        : headingDirection;

    _guidanceSoundService.updateDirectionalGuidance(
      isActive: isDirectionalGuidanceActive,
      severity: guidanceSeverity,
      direction: guidanceDirection,
      headingErrorDeg: headingErrorDeg,
      relativeAngleDeg: relativeAngleDeg,
      sourceDistanceMeters: _spatialCueDistanceMeters,
      distanceToWaypointMeters: _distanceToNextWaypointMeters(session),
    );

    final eventType = session.latestGuidanceEventType;
    if (eventType == null) return;
    if (eventType.name == 'trackingUpdated') return;

    if (eventType == GuidanceEventType.offRoute &&
        _lastGuidanceCueSignature == 'offRoute:${session.trackingState.name}') {
      return;
    }

    final cueSignature = eventType == GuidanceEventType.offRoute
        ? 'offRoute:${session.trackingState.name}'
        : '${eventType.name}:${session.nextWaypointIndex}:${session.trackingState.name}';
    if (_lastGuidanceCueSignature == cueSignature) return;
    _lastGuidanceCueSignature = cueSignature;
    unawaited(_guidanceSoundService.playCue(eventType));
  }

  Future<void> _toggleSpatialAudioExperiment() async {
    final nextValue = !_spatialAudioExperimentEnabled;
    setState(() {
      _spatialAudioExperimentEnabled = nextValue;
    });

    if (!nextValue) {
      _spatialAudioExperimentActivated = false;
      await _guidanceSoundService.disableSpatial();
      await _refreshAudioOutputStatus();
      return;
    }

    await _maybeActivateSpatialAudioForSession(_navigationController.session);
  }

  Future<void> _maybeActivateSpatialAudioForSession(NavigationSession session) async {
    if (!_spatialAudioExperimentEnabled || !Platform.isIOS) return;
    if (_spatialAudioExperimentActivated) return;
    if (session.route == null || session.currentPose == null) return;
    if (session.trackingState == TrackingState.idle ||
        session.trackingState == TrackingState.localizing) {
      return;
    }

    final enabled = await _guidanceSoundService.enableSpatial();
    if (!mounted) return;
    if (enabled) {
      _spatialAudioExperimentActivated = true;
      await _guidanceSoundService.primeDirectionalGuidance();
    }
    await _refreshAudioOutputStatus();
  }

  Future<void> _reconcileAudioOutputRouting(NavigationSession session) async {
    await _refreshAudioOutputStatus();
    if (!mounted || !Platform.isIOS) return;

    final shouldUseSpatial = _spatialAudioExperimentEnabled &&
        _audioOutputStatus.supportsSpatial &&
        _audioOutputStatus.hasHeadphonesConnected &&
        !_audioOutputStatus.isMonoAudioEnabled &&
        session.route != null &&
        session.currentPose != null &&
        session.trackingState != TrackingState.idle &&
        session.trackingState != TrackingState.localizing;

    if (shouldUseSpatial) {
      if (!_spatialAudioExperimentActivated) {
        await _maybeActivateSpatialAudioForSession(session);
      }
      return;
    }

    if (_spatialAudioExperimentActivated) {
      _spatialAudioExperimentActivated = false;
      await _guidanceSoundService.disableSpatial();
      await _refreshAudioOutputStatus();
    }
  }

  void _emitHeadingLatchHapticIfNeeded(bool headingAligned) {
    final previous = _lastHeadingAligned;
    _lastHeadingAligned = headingAligned;
    if (previous == null || previous == headingAligned) return;

    if (headingAligned) {
      unawaited(_playLatchHaptic(lockedIn: true));
    } else {
      unawaited(_playLatchHaptic(lockedIn: false));
    }
  }

  Future<void> _playLatchHaptic({required bool lockedIn}) async {
    if (lockedIn) {
      await HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      await HapticFeedback.selectionClick();
      return;
    }

    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await HapticFeedback.lightImpact();
  }

  double _headingErrorToNextWaypoint(NavigationSession session) {
    final pose = session.currentPose;
    final path = session.trackedPath;
    if (pose == null || path.length < 2) return 180;

    final current = path.first;
    final next = path[1];
    final delta = next - current;
    if (delta.distance <= 1e-3) return 0;

    final bearingDeg = _normalizeDegrees(
      math.atan2(-delta.dy, delta.dx) * 180 / math.pi,
    );
    final diff = (bearingDeg - pose.heading).abs();
    return diff > 180 ? 360 - diff : diff;
  }

  AudioCueDirection _headingCueDirectionToNextWaypoint(
    NavigationSession session,
  ) {
    final signed = _signedHeadingDeltaToNextWaypoint(session);
    if (signed.abs() <= _headingLockThresholdDeg)
      return AudioCueDirection.center;
    return signed > 0 ? AudioCueDirection.left : AudioCueDirection.right;
  }

  double _signedHeadingDeltaToNextWaypoint(NavigationSession session) {
    final pose = session.currentPose;
    final path = session.trackedPath;
    if (pose == null || path.length < 2) return 0;

    final current = path.first;
    final next = path[1];
    final delta = next - current;
    if (delta.distance <= 1e-3) return 0;

    final bearingDeg = _normalizeDegrees(
      math.atan2(-delta.dy, delta.dx) * 180 / math.pi,
    );
    return _signedHeadingDeltaDeg(pose.heading, bearingDeg);
  }

  double _signedHeadingDeltaDeg(double currentDeg, double targetDeg) {
    var delta = (targetDeg - currentDeg + 540) % 360 - 180;
    if (delta < -180) {
      delta += 360;
    }
    return delta;
  }

  double _normalizedHeadingSeverity(double headingErrorDeg) {
    const start = _headingLockThresholdDeg;
    const end = 70.0;
    final normalized = (headingErrorDeg - start) / (end - start);
    return normalized.clamp(0.0, 1.0);
  }

  double _guidancePulseIntervalSeconds({
    required double headingErrorDeg,
    required double distanceToWaypointMeters,
  }) {
    const minFrequencyHz = 0.5;
    const maxHeadingFrequencyHz = 2.0;
    const maxDistanceFrequencyHz = 3.4;
    final normalizedAngle = (headingErrorDeg.abs() / 180.0).clamp(0.0, 1.0);
    final headingFrequencyHz =
        minFrequencyHz +
        ((maxHeadingFrequencyHz - minFrequencyHz) * normalizedAngle);
    final normalizedDistance =
        ((6.0 - distanceToWaypointMeters) / (6.0 - 0.8)).clamp(0.0, 1.0);
    final distanceFrequencyHz =
        minFrequencyHz +
        ((maxDistanceFrequencyHz - minFrequencyHz) * normalizedDistance);
    final frequencyHz = math.max(headingFrequencyHz, distanceFrequencyHz);
    return 1.0 / frequencyHz;
  }

  double _distanceToNextWaypointMeters(NavigationSession session) {
    final metersPerPixel = _navigationController.metersPerPixel;
    if (metersPerPixel == null || metersPerPixel <= 0) {
      return session.distanceToNextWaypointPx;
    }
    return session.distanceToNextWaypointPx * metersPerPixel;
  }

  int? _nextDistanceCountdownMark(double distanceMeters) {
    if (distanceMeters > 5.0) return null;
    if (distanceMeters <= 1.0) return 1;
    if (distanceMeters <= 2.0) return 2;
    if (distanceMeters <= 3.0) return 3;
    if (distanceMeters <= 4.0) return 4;
    return 5;
  }

  String? _buildDistanceAnnouncement(
    double distanceMeters, {
    required int countdownMark,
  }) {
    final settings = context.read<SettingsProvider>();
    final lang = settings.languageCode;
    if (countdownMark < 5) {
      return countdownMark.toString();
    }
    if (settings.unit == 'feet') {
      final distanceFeet = distanceMeters * 3.28084;
      final roundedFeet = _formatSpokenDistanceValue(
        distanceFeet,
        integerThreshold: 10,
      );
      if (lang == 'zh') return '前方 $roundedFeet 英尺。';
      if (lang == 'th') return 'ข้างหน้า $roundedFeet ฟุต';
      return '$roundedFeet feet ahead.';
    }

    final roundedMeters = _formatSpokenDistanceValue(
      distanceMeters,
      integerThreshold: 10,
    );
    if (lang == 'zh') return '前方 $roundedMeters 米。';
    if (lang == 'th') return 'ข้างหน้า $roundedMeters เมตร';
    return '$roundedMeters meters ahead.';
  }

  String _formatSpokenDistanceValue(
    double value, {
    required double integerThreshold,
  }) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.05) {
      return rounded.toInt().toString();
    }
    if (value >= integerThreshold) {
      return value.round().toString();
    }
    return value.toStringAsFixed(1);
  }

  double _normalizeDegrees(double value) {
    var normalized = value % 360;
    if (normalized < 0) {
      normalized += 360;
    }
    return normalized;
  }

  Future<void> _handleError(String? err) async {
    final lang = context.read<SettingsProvider>().languageCode;
    final msg = _navigationController.buildErrorMessage(
      languageCode: lang,
      backendError: err,
    );
    await TTSService.setLanguage(lang);
    await TTSService.speak(msg);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
    }
  }

  Future<void> _syncArOverlay(NavigationSession session) async {
    if (!_usesNativeArPreview) return;

    try {
      final snapshot = _navigationController.buildArOverlaySnapshot();
      if (snapshot == null ||
          (snapshot.activePathWorldPoints.isEmpty &&
              snapshot.futurePathWorldPoints.isEmpty)) {
        await _arMethodChannel.invokeMethod<void>(
          ArChannelContract.clearOverlayMethod,
        );
        return;
      }

      Map<String, double>? encodePoint(math.Point<double>? point) {
        if (point == null) return null;
        return <String, double>{
          ArChannelContract.xKey: point.x,
          ArChannelContract.yKey: snapshot.worldY,
          ArChannelContract.zKey: point.y,
        };
      }

      await _arMethodChannel.invokeMethod<void>(
        ArChannelContract.updateOverlayMethod,
        {
          ArChannelContract.activePathPointsKey: snapshot.activePathWorldPoints
              .map(
                (point) => <String, double>{
                  ArChannelContract.xKey: point.x,
                  ArChannelContract.yKey: snapshot.worldY,
                  ArChannelContract.zKey: point.y,
                },
              )
              .toList(growable: false),
          ArChannelContract.futurePathPointsKey: snapshot.futurePathWorldPoints
              .map(
                (point) => <String, double>{
                  ArChannelContract.xKey: point.x,
                  ArChannelContract.yKey: snapshot.worldY,
                  ArChannelContract.zKey: point.y,
                },
              )
              .toList(growable: false),
          ArChannelContract.nextWaypointKey: encodePoint(
            snapshot.nextWaypointWorldPoint,
          ),
          ArChannelContract.destinationKey: encodePoint(
            snapshot.destinationWorldPoint,
          ),
          ArChannelContract.waypointPulseActiveKey:
              session.trackingState != TrackingState.arrived &&
              snapshot.nextWaypointWorldPoint != null,
          ArChannelContract.waypointPulsePeriodSecKey:
              _guidancePulseIntervalSeconds(
                headingErrorDeg: _headingErrorToNextWaypoint(session),
                distanceToWaypointMeters: _distanceToNextWaypointMeters(session),
              ),
        },
      );
    } catch (_) {}
  }

  Future<void> _announcePlaybackMode() async {
    final lang = context.read<SettingsProvider>().languageCode;
    final msg = _navigationController.buildPlaybackModeAnnouncement(
      languageCode: lang,
      playFullCommands: _playFullCommands,
    );
    await TTSService.setLanguage(lang);
    await TTSService.speak(msg);
  }

  // ========================= UI Building =========================

  Widget _buildCameraPreview(Orientation orientation) {
    if (_usesNativeArPreview) {
      final width = orientation == Orientation.portrait ? 120.0 : 180.0;
      final height = orientation == Orientation.portrait ? 180.0 : 120.0;
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: width,
          height: height,
          child: Platform.isIOS
              ? const UiKitView(
                  viewType: ArChannelContract.previewViewType,
                  layoutDirection: TextDirection.ltr,
                )
              : const AndroidView(
                  viewType: ArChannelContract.previewViewType,
                  layoutDirection: TextDirection.ltr,
                ),
        ),
      );
    }

    if (!_isCameraInitialized || _cameraController == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: Colors.black38,
          width: orientation == Orientation.portrait ? 120 : 180,
          height: orientation == Orientation.portrait ? 180 : 120,
          child: const Center(
            child: Icon(Icons.videocam_off, color: Colors.white),
          ),
        ),
      );
    }
    final width = orientation == Orientation.portrait ? 120.0 : 180.0;
    final height = orientation == Orientation.portrait ? 180.0 : 120.0;

    return GestureDetector(
      onTap: _onTapCapture,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: width,
          height: height,
          color: Colors.black,
          child: SizedBox.expand(
            child: KeyedSubtree(
              key: ValueKey(_cameraPreviewVersion),
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: orientation == Orientation.portrait ? 3 : 4,
                  height: orientation == Orientation.portrait ? 4 : 3,
                  child: CameraPreview(_cameraController!),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaybackToggleButton() {
    return IconButton(
      icon: Icon(
        _playFullCommands ? Icons.playlist_play : Icons.navigation,
        size: 32,
        color: Colors.white,
      ),
      tooltip: _playFullCommands ? 'Full playback' : 'Step playback',
      onPressed: () async {
        setState(() => _playFullCommands = !_playFullCommands);
        await _announcePlaybackMode();
      },
    );
  }

  Widget _buildRelocalizeButton() {
    return ElevatedButton.icon(
      onPressed: _isLoading ? null : _onTapCapture,
      icon: const Icon(Icons.camera_alt_rounded),
      label: const Text('Relocalize'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.78),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget? _buildAudioStatusBanner() {
    if (!Platform.isIOS) return null;

    String? message;
    Color background = Colors.black.withValues(alpha: 0.76);
    Color foreground = Colors.white;

    if (_audioOutputStatus.isMonoAudioEnabled) {
      message =
          'Mono Audio is on. Turn it off in Accessibility > Audio & Visual for spatial cues.';
      background = Colors.orange.withValues(alpha: 0.92);
      foreground = Colors.black;
    } else if (_spatialAudioExperimentEnabled &&
        !_audioOutputStatus.hasHeadphonesConnected) {
      message =
          'Spatial cues work best with headphones or AirPods. Current output is using stereo fallback.';
    } else if (_spatialAudioExperimentEnabled &&
        _audioOutputStatus.supportsSpatial) {
      message = _spatialAudioExperimentActivated
          ? 'Spatial guidance active: cues are placed toward the next waypoint.'
          : 'Spatial guidance armed. Start tracking to activate HRTF cues.';
      background = Colors.teal.withValues(alpha: 0.86);
    } else if (!_spatialAudioExperimentEnabled &&
        _audioOutputStatus.supportsSpatial) {
      message = 'Spatial guidance available. It will activate automatically when tracking starts.';
    }

    if (message == null) return null;

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final canvasW = constraints.maxWidth;
          final canvasH = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: _onTapCapture,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_floorplanBytes != null)
                      Image.memory(
                        _floorplanBytes!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      )
                    else
                      Container(color: Colors.grey[200]),
                    if (_currentPath.isNotEmpty &&
                        _decodedFloorplanImage != null)
                      CustomPaint(
                        size: Size(canvasW, canvasH),
                        painter: FloorplanPathPainter(
                          pathPoints: _currentPath,
                          floorplanImage: _decodedFloorplanImage,
                          headingAngleDeg: _navigationController
                              .session
                              .currentPose
                              ?.heading,
                          firstPersonView: _firstPerson,
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                bottom: 24,
                right: 16,
                child: _buildCameraPreview(orientation),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: _buildRelocalizeButton(),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            setState(() => _firstPerson = !_firstPerson),
                        child: CircleAvatar(
                          radius: 24,
                          backgroundImage:
                              Provider.of<SettingsProvider>(
                                    context,
                                    listen: false,
                                  ).avatarUrl !=
                                  null
                              ? NetworkImage(
                                  Provider.of<SettingsProvider>(
                                    context,
                                    listen: false,
                                  ).avatarUrl!,
                                )
                              : const AssetImage(
                                      'assets/avatar_placeholder.png',
                                    )
                                    as ImageProvider,
                        ),
                      ),
                      const SizedBox(height: 12),
                      GuidanceBanner(
                        trackingState:
                            _navigationController.session.trackingState,
                        message:
                            _navigationController.session.latestGuidanceMessage,
                        remainingDistancePx:
                            _navigationController.session.remainingDistancePx,
                        distanceToNextWaypointPx: _navigationController
                            .session
                            .distanceToNextWaypointPx,
                      ),
                      if (_buildAudioStatusBanner() case final banner?) banner,
                    ],
                  ),
                ),
              ),
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(
                      Icons.arrow_back,
                      size: 32,
                      color: Colors.white,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),

              // Playback mode toggle button (top-right)
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _buildPlaybackToggleButton(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
