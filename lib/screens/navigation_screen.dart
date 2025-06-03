import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
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

/// NavigationScreen overlays the navigation path over the floorplan,
/// and displays a floating camera preview for localization input.
/// It supports multi-language TTS based on the current user setting.
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
    Key? key,
    required this.selectedPlaceId,
    required this.selectedPlaceName,
    required this.selectedBuildingId,
    required this.selectedBuildingName,
    required this.selectedFloorId,
    required this.selectedFloorName,
    required this.selectedDestinationId,
    required this.selectedDestinationName,
  }) : super(key: key);

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> with WidgetsBindingObserver {
  Uint8List? _floorplanBytes;
  ui.Image? _decodedFloorplanImage;
  String? _lastMapKey;
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isLoading = false;
  Map<String, dynamic>? _navResultData; // Stores server response (for path, pose, etc.)
  List<Offset> _currentPath = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchFloorplan();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  /// Handles app lifecycle transitions for camera safety.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  /// Loads the floorplan image from backend and decodes for painting.
  Future<void> _fetchFloorplan() async {
    try {
      final fp = await ApiService.getFloorplan();
      if (fp != null) {
        decodeImageFromList(fp).then((ui.Image img) {
          if (mounted) {
            setState(() {
              _floorplanBytes = fp;
              _decodedFloorplanImage = img;
            });
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _floorplanBytes = null;
          _decodedFloorplanImage = null;
        });
      }
    }
  }

  /// Initializes the camera for preview/capture.
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
      if (mounted) {
        setState(() {
          _cameraController?.dispose();
          _cameraController = controller;
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isCameraInitialized = false);
    }
  }

  /// Extracts a navigation command group for TTS:
  /// - Start from [lastCmdIndex].
  /// - Collects all up to and including the first "forward".
  /// - Then collects any non-action sentences after the forward,
  ///   stopping at the next "turn"/"forward" or end of list.
  List<String> _extractCurrentCommandGroup(List<String> cmds) {
    if (cmds.isEmpty) return [];
    final lang = context.read<SettingsProvider>().languageCode;
    final result = <String>[];
    bool foundForward = false;
    int i = 0;

    // Step 1: Collect until (and including) the first "forward"
    for (; i < cmds.length; ++i) {
      result.add(cmds[i]);
      if (_isForwardCmd(cmds[i].toLowerCase(), lang)) {
        foundForward = true;
        i++;  // move to next after forward
        break;
      }
    }
    if (!foundForward) {
      // No forward found, return what we've got (could be only context/turn)
      return result;
    }

    // Step 2: Collect subsequent non-action hints (landmarks, etc)
    for (; i < cmds.length; ++i) {
      if (_isTurnCmd(cmds[i].toLowerCase(), lang) || _isForwardCmd(cmds[i].toLowerCase(), lang)) {
        // Stop at next action
        break;
      }
      result.add(cmds[i]);
    }

    return result;
  }

  /// Determines if the command is a "turn" (direction adjustment).
  bool _isTurnCmd(String cmd, String lang) {
    final keys = turnKeywords[lang] ?? turnKeywords['en']!;
    return keys.any((k) => cmd.contains(k));
  }
  /// Determines if the command is a "forward" action.
  bool _isForwardCmd(String cmd, String lang) {
    final keys = forwardKeywords[lang] ?? forwardKeywords['en']!;
    return keys.any((k) => cmd.contains(k));
  }
  /// Handles camera capture, sends image to backend, updates path, and triggers TTS for the current chunk.
  Future<void> _captureAndSend() async {
    if (_isLoading || !_isCameraInitialized || _cameraController == null) return;
    setState(() => _isLoading = true);

    try {
      final file = await _cameraController!.takePicture();
      final bytes = await file.readAsBytes();
      final result = await ApiService.unavNavigation(bytes, "query.jpg");

      if (!mounted) return;

      // 1. Handle error: result can be { "error": "..."} or any abnormal type
      if (result is Map<String, dynamic> && result.containsKey('error')) {
        final lang = context.read<SettingsProvider>().languageCode;
        await TTSService.setLanguage(lang);
        String msg = result['error']?.toString() ?? "Unknown error.";
        // Optionally: multi-language mapping of common errors
        if (lang == "zh") {
          if (msg == "Localization failed, no pose found.") msg = "定位失败，未找到位姿。";
        } else if (lang == "th") {
          if (msg == "Localization failed, no pose found.") msg = "ไม่พบตำแหน่งของคุณ";
        }
        // Add other error mapping here
        await TTSService.speak(msg);
        // Also可用SnackBar弹出提示（UI）
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red),
          );
        }
        return;
      }

      // 2. Proceed with normal result (must have cmds etc.)
      final List<dynamic> pathKeys = result["result"]?["path_keys"] ?? [];
      final List<dynamic> pathCoords = result["result"]?["path_coords"] ?? [];
      final floorSegs = splitPathByFloor(pathKeys, pathCoords);

      // Multi-language commands: already localized from backend
      List<String> cmds = List<String>.from(result["cmds"] ?? []);
      if (cmds.isNotEmpty) {
        final lang = context.read<SettingsProvider>().languageCode;
        await TTSService.setLanguage(lang);
        final group = _extractCurrentCommandGroup(cmds);
        TTSService.speakSequentially(group);
      }

      final dynamic bestMapKey = result["best_map_key"];
      final String currMapKey = (bestMapKey as List).take(3).join('|');
      if (currMapKey != _lastMapKey) {
        await _fetchFloorplan();
        _lastMapKey = currMapKey;
      }

      setState(() {
        _navResultData = result;
        _currentPath = floorSegs[currMapKey] ?? [];
      });
    } catch (e) {
      // 3. Handle network and system errors with TTS + SnackBar
      final lang = context.read<SettingsProvider>().languageCode;
      String msg = "Network or internal error.";
      if (lang == "zh") msg = "网络或内部错误。";
      else if (lang == "th") msg = "เกิดข้อผิดพลาดของระบบหรือเครือข่าย";
      await TTSService.setLanguage(lang);
      await TTSService.speak(msg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Builds the floating camera preview widget for the bottom-right corner.
  Widget _buildCameraPreview(Orientation orientation) {
    if (!_isCameraInitialized || _cameraController == null) {
      // Show a placeholder if the camera is not ready.
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: Colors.black38,
          width: orientation == Orientation.portrait ? 120 : 160,
          height: orientation == Orientation.portrait ? 160 : 120,
          child: const Center(
            child: Icon(Icons.videocam_off, color: Colors.white),
          ),
        ),
      );
    }

    final previewSize = _cameraController!.value.previewSize;
    if (previewSize == null) {
      // Defensive: show placeholder.
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: Colors.black38,
          width: orientation == Orientation.portrait ? 120 : 160,
          height: orientation == Orientation.portrait ? 160 : 120,
          child: const Center(
            child: Icon(Icons.videocam_off, color: Colors.white),
          ),
        ),
      );
    }

    // Choose correct aspect ratio for preview window.
    final double aspectRatio = orientation == Orientation.portrait
        ? previewSize.height / previewSize.width
        : previewSize.width / previewSize.height;
    final double base = 200.0; // Base window size.
    final double width = orientation == Orientation.portrait ? base * aspectRatio : base;
    final double height = orientation == Orientation.portrait ? base : base / aspectRatio;

    return GestureDetector(
      onTap: _captureAndSend,
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

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;

    // Main layout: overlays camera preview and path painter on top of floorplan background.
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final double canvasWidth = constraints.maxWidth;
          final double canvasHeight = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Floorplan image + navigation path painter
              GestureDetector(
                onTap: _captureAndSend,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // ---- Floorplan background ----
                    if (_floorplanBytes != null)
                      Image.memory(
                        _floorplanBytes!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      )
                    else
                      Container(color: Colors.grey[200]),

                    // ---- Path overlay (current floor only) ----
                    if (_currentPath.isNotEmpty && _decodedFloorplanImage != null)
                      CustomPaint(
                        size: Size(canvasWidth, canvasHeight),
                        painter: FloorplanPathPainter(
                          pathPoints: _currentPath,
                          floorplanImage: _decodedFloorplanImage,
                          headingAngleDeg: _navResultData?['floorplan_pose']?['ang']?.toDouble(),
                        ),
                      ),
                  ],
                ),
              ),

              // Camera preview floating window (bottom-right)
              Positioned(
                bottom: 24,
                right: 16,
                child: _buildCameraPreview(orientation),
              ),

              // Loading indicator (center)
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),

              // Back button (top-left)
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, size: 32, color: Colors.black87),
                    onPressed: () => Navigator.of(context).pop(),
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
