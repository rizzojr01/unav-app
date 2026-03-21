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
import '../features/navigation/infrastructure/tracking/pose_provider_factory.dart';
import '../features/navigation/presentation/widgets/guidance_banner.dart';
import '../widgets/floorplan_path_painter.dart';
import '../services/tts_service.dart';
import '../providers/settings_provider.dart';

const Map<String, List<String>> turnKeywords = {
  'en': ['turn', 'slight left', 'slight right', 'sharp right', 'sharp left', 'u-turn'],
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

class _NavigationScreenState extends State<NavigationScreen> with WidgetsBindingObserver {
  static const double _headingLockThresholdDeg = 3.0;
  static const double _spatialCueDistanceMeters = 2.0;
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
  bool? _lastHeadingAligned;
  AudioOutputStatus _audioOutputStatus = const AudioOutputStatus.unknown();

  // ---- Camera state ----
  CameraController? _cameraController;
  final MethodChannel _arMethodChannel = const MethodChannel(ArChannelContract.methodChannel);
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
      Platform.isIOS && _poseProviderBundle.mode == PoseProviderMode.nativeAr;

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
          ? GuidanceAudioMode.spatial
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _speechDebounceTimer?.cancel();
    _navigationController.dispose();
    _poseProviderBundle.dispose();
    _guidanceSoundService.dispose();
    _playerSend.dispose();
    super.dispose();
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
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
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
      await AudioPlayer.global.setAudioContext(const AudioContext(
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
      ));
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
        {
          ArChannelContract.backendKey: 'iosArKit',
        },
      );
    } catch (_) {}
  }

  Future<Uint8List?> _capturePreviewFrameBytes() async {
    if (_usesNativeArPreview) {
      await _ensureArPreviewSessionStarted();
      final bytes = await _arMethodChannel.invokeMethod<Uint8List>(
        ArChannelContract.captureCurrentFrameMethod,
        {
          ArChannelContract.backendKey: 'iosArKit',
        },
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
    if (!_usesNativeArPreview && (!_isCameraInitialized || _cameraController == null)) return;
    setState(() => _isLoading = true);

    // 1) Play cue first
    await _playSendCue();

    // 2) Delay a bit to avoid focus race with camera shutter
    await Future.delayed(const Duration(milliseconds: 150)); // 150ms for extra safety

    try {
      final fixedBytes = await _capturePreviewFrameBytes();
      if (fixedBytes == null) {
        await _handleError(null);
        return;
      }
      final result = await ApiService.unavNavigation(fixedBytes, 'query.jpg');
      if (!mounted) return;

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

    setState(() {
      _currentPath = processingResult.session.trackedPath;
    });
    _playGuidanceCueIfNeeded(processingResult.session);

    final route = processingResult.session.route;
    if (route != null && route.points.length > 1) {
      final referencePose = processingResult.session.currentPose;
      final floorScale = await ApiService.getCurrentFloorScale();
      if (referencePose != null && floorScale != null) {
        final metersPerPixel = provider.unit == 'feet' ? floorScale * 0.3048 : floorScale;
        _navigationController.configureArTrackingAlignment(
          referenceFloorplanPose: referencePose,
          metersPerPixel: metersPerPixel,
        );
      }
      final mockRouteProvider = _poseProviderBundle.mockRouteProvider;
      mockRouteProvider?.loadRoute(route);
      try {
        await _navigationController.startPoseTracking(_handleTrackingSessionUpdated);
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

    _playGuidanceCueIfNeeded(session);

    if (session.latestGuidanceEventType == GuidanceEventType.offRoute) {
      return;
    }

    final msg = session.latestGuidanceMessage;
    if (msg == null || msg.isEmpty) return;
    _speechDebounceTimer?.cancel();
    _speechDebounceTimer = Timer(const Duration(milliseconds: 50), () async {
      await TTSService.setLanguage(context.read<SettingsProvider>().languageCode);
      await TTSService.speak(msg);
    });
  }

  void _playGuidanceCueIfNeeded(NavigationSession session) {
    final headingErrorDeg = _headingErrorToNextWaypoint(session);
    final relativeAngleDeg = _signedHeadingDeltaToNextWaypoint(session);
    final headingDirection = _headingCueDirectionToNextWaypoint(session);
    final headingAligned = headingErrorDeg <= _headingLockThresholdDeg;
    _emitHeadingLatchHapticIfNeeded(headingAligned);

    final isDirectionalGuidanceActive =
        session.trackingState == TrackingState.offRoute || headingErrorDeg > _headingLockThresholdDeg;
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

  AudioCueDirection _headingCueDirectionToNextWaypoint(NavigationSession session) {
    final signed = _signedHeadingDeltaToNextWaypoint(session);
    if (signed.abs() <= _headingLockThresholdDeg) return AudioCueDirection.center;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
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
          child: const UiKitView(
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
          child: const Center(child: Icon(Icons.videocam_off, color: Colors.white)),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Widget? _buildAudioStatusBanner() {
    if (!Platform.isIOS) return null;

    String? message;
    Color background = Colors.black.withValues(alpha: 0.76);
    Color foreground = Colors.white;

    if (_audioOutputStatus.isMonoAudioEnabled) {
      message = 'Mono Audio is on. Turn it off in Accessibility > Audio & Visual for spatial cues.';
      background = Colors.orange.withValues(alpha: 0.92);
      foreground = Colors.black;
    } else if (_enableSpatialAudioExperiment && !_audioOutputStatus.hasHeadphonesConnected) {
      message = 'Spatial cues work best with headphones or AirPods. Current output is using stereo fallback.';
    } else if (_enableSpatialAudioExperiment && _audioOutputStatus.supportsSpatial) {
      message = 'Spatial guidance active: cues are placed toward the next waypoint.';
      background = Colors.teal.withValues(alpha: 0.86);
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
                    if (_currentPath.isNotEmpty && _decodedFloorplanImage != null)
                      CustomPaint(
                        size: Size(canvasW, canvasH),
                        painter: FloorplanPathPainter(
                          pathPoints: _currentPath,
                          floorplanImage: _decodedFloorplanImage,
                          headingAngleDeg: _navigationController.session.currentPose?.heading,
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
                        onTap: () => setState(() => _firstPerson = !_firstPerson),
                        child: CircleAvatar(
                          radius: 24,
                          backgroundImage:
                              Provider.of<SettingsProvider>(context, listen: false).avatarUrl != null
                                  ? NetworkImage(
                                      Provider.of<SettingsProvider>(context, listen: false).avatarUrl!)
                                  : const AssetImage('assets/avatar_placeholder.png')
                                      as ImageProvider,
                        ),
                      ),
                      const SizedBox(height: 12),
                      GuidanceBanner(
                        trackingState: _navigationController.session.trackingState,
                        message: _navigationController.session.latestGuidanceMessage,
                        remainingDistancePx: _navigationController.session.remainingDistancePx,
                        distanceToNextWaypointPx:
                            _navigationController.session.distanceToNextWaypointPx,
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
                    icon: const Icon(Icons.arrow_back, size: 32, color: Colors.white),
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
