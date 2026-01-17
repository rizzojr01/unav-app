// lib/screens/navigation_screen.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart'; // HapticFeedback + rootBundle
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:audioplayers/audioplayers.dart';

import '../api/api_service.dart';
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
  // ---- Floorplan / path rendering state ----
  Uint8List? _floorplanBytes;
  ui.Image? _decodedFloorplanImage;
  String? _lastMapKey;
  Map<String, dynamic>? _navResultData;
  List<Offset> _currentPath = [];

  // ---- Camera state ----
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isLoading = false;

  // ---- UI mode ----
  bool _firstPerson = false;

  // ---- TTS play mode ----
  // false: speak only the "current step group"
  // true : speak all cmds (full route playback)
  bool _playFullCommands = false;

  // ---- Low-latency UI sound (audioplayers) ----
  late final AudioPlayer _playerSend;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _configureAudioForUiSounds(); // set audio context
    _initUiSoundPlayer(); // prepare player + preload asset

    _fetchFloorplan();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _playerSend.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
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
          category: AVAudioSessionCategory.ambient,
          options: [AVAudioSessionOptions.mixWithOthers],
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
      await _playerSend.setSource(AssetSource('assets/sounds/send.wav')); // wav is fine
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
    try {
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
        _cameraController?.dispose();
        _cameraController = controller;
        _isCameraInitialized = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCameraInitialized = false);
    }
  }

  // ========================= Capture & Send =========================

  void _onTapCapture() {
    _captureAndSend();
  }

  /// Play a short local audio + haptic when sending begins.
  Future<void> _playSendCue() async {
    try {
      // Restart from zero to guarantee the sound plays immediately
      await _playerSend.seek(Duration.zero);
      await _playerSend.resume();
      await HapticFeedback.mediumImpact();
      await HapticFeedback.vibrate();
    } catch (_) {}
  }

  Future<void> _captureAndSend() async {
    if (_isLoading || !_isCameraInitialized || _cameraController == null) return;
    setState(() => _isLoading = true);

    // 1) Play cue first
    await _playSendCue();

    // 2) Delay a bit to avoid focus race with camera shutter
    await Future.delayed(const Duration(milliseconds: 150)); // 150ms for extra safety

    try {
      final file = await _cameraController!.takePicture();
      final rawBytes = await file.readAsBytes();
      final fixedBytes = await fixImageOrientation(rawBytes);
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
    }
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
    final pathKeys = result['result']?['path_keys'] ?? [];
    final pathCoords = result['result']?['path_coords'] ?? [];
    final floorSegs = splitPathByFloor(pathKeys, pathCoords);

    final List<dynamic> cmdsRaw = result['cmds'] ?? [];
    List<Map<String, dynamic>> cmds =
        cmdsRaw.whereType<Map<String, dynamic>>().cast<Map<String, dynamic>>().toList();

    // Filter commands based on announceCurrentLocation setting
    final provider = context.read<SettingsProvider>();
    if (!provider.announceCurrentLocation) {
      cmds = cmds.where((cmd) {
        final tag = cmd['tag'] as String?;
        return tag != 'start_in';
      }).toList();
    }

    if (cmds.isNotEmpty) {
      final lang = provider.languageCode;
      await TTSService.setLanguage(lang);

      // Choose playback mode:
      // - Step-by-step: current command group
      // - Full: all commands
      final List<Map<String, dynamic>> toSpeakCmds =
          _playFullCommands ? cmds : _extractCurrentCommandGroup(cmds);

      final texts = toSpeakCmds
          .map((cmd) => cmd['text'] as String? ?? '')
          .where((t) => t.isNotEmpty)
          .toList();

      if (texts.isNotEmpty) {
        // Note: This is intentionally not awaited; it depends on TTSService internal queueing.
        TTSService.speakSequentially(texts);
      }
    }

    final mapKey = (result['best_map_key'] as List).take(3).join('|');
    if (mapKey != _lastMapKey) {
      await _fetchFloorplan();
      _lastMapKey = mapKey;
    }

    setState(() {
      _navResultData = result;
      _currentPath = floorSegs[_lastMapKey!] ?? [];
    });
  }

  Future<void> _handleError(String? err) async {
    final lang = context.read<SettingsProvider>().languageCode;
    final msg = err?.isNotEmpty == true
        ? err!
        : lang == 'zh'
            ? '网络或内部错误。'
            : lang == 'th'
                ? 'เกิดข้อผิดพลาดของระบบหรือเครือข่าย'
                : 'Network or internal error.';
    await TTSService.setLanguage(lang);
    await TTSService.speak(msg);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  List<Map<String, dynamic>> _extractCurrentCommandGroup(List<Map<String, dynamic>> cmds) {
    if (cmds.isEmpty) return [];
    final result = <Map<String, dynamic>>[];
    bool foundForward = false;
    int i = 0;

    // 1) Add commands until the first forward (inclusive)
    for (; i < cmds.length; ++i) {
      result.add(cmds[i]);
      if (_isForwardTag(cmds[i]['tag'])) {
        foundForward = true;
        i++;
        break;
      }
    }

    // If no forward found, return what we collected (could be all cmds)
    if (!foundForward) return result;

    // 2) After forward, include extra hints until the next turn/forward appears
    for (; i < cmds.length; ++i) {
      final tag = cmds[i]['tag'] as String? ?? '';
      if (_isTurnTag(tag) || _isForwardTag(tag)) break;
      result.add(cmds[i]);
    }
    return result;
  }

  bool _isForwardTag(String? tag) => tag == 'forward' || tag == 'forward_door';
  bool _isTurnTag(String? tag) => tag == 'turn' || tag == 'u_turn';

  Future<void> _announcePlaybackMode() async {
    final lang = context.read<SettingsProvider>().languageCode;
    final msg = _playFullCommands
        ? (lang == 'zh'
            ? '已切换为全程播报'
            : lang == 'th'
                ? 'สลับเป็นการบอกเส้นทางทั้งหมด'
                : 'Switched to full instructions')
        : (lang == 'zh'
            ? '已切换为分步播报'
            : lang == 'th'
                ? 'สลับเป็นการบอกทีละขั้น'
                : 'Switched to step-by-step instructions');
    await TTSService.setLanguage(lang);
    await TTSService.speak(msg);
  }

  // ========================= UI Building =========================

  Widget _buildCameraPreview(Orientation orientation) {
    if (!_isCameraInitialized || _cameraController == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: Colors.black38,
          width: orientation == Orientation.portrait ? 120 : 160,
          height: orientation == Orientation.portrait ? 160 : 120,
          child: const Center(child: Icon(Icons.videocam_off, color: Colors.white)),
        ),
      );
    }
    final previewSize = _cameraController!.value.previewSize;
    if (previewSize == null) return _buildCameraPreview(orientation);
    final aspectRatio = orientation == Orientation.portrait
        ? previewSize.height / previewSize.width
        : previewSize.width / previewSize.height;
    const base = 200.0;
    final width = orientation == Orientation.portrait ? base * aspectRatio : base;
    final height = orientation == Orientation.portrait ? base : base / aspectRatio;

    return GestureDetector(
      onTap: _onTapCapture,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: width,
          height: height,
          color: Colors.black,
          child: CameraPreview(_cameraController!),
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
                          headingAngleDeg:
                              (_navResultData?['floorplan_pose']?['ang'] as num?)?.toDouble(),
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
                  alignment: Alignment.topCenter,
                  child: GestureDetector(
                    onTap: () => setState(() => _firstPerson = !_firstPerson),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundImage:
                          Provider.of<SettingsProvider>(context, listen: false).avatarUrl != null
                              ? NetworkImage(
                                  Provider.of<SettingsProvider>(context, listen: false).avatarUrl!)
                              : const AssetImage('assets/avatar_placeholder.png') as ImageProvider,
                    ),
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
