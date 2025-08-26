import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
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
/// displays a floating camera preview for localization input,
/// supports single-tap capture and toggles between first- and third-person views.
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
  Uint8List? _floorplanBytes;
  ui.Image? _decodedFloorplanImage;
  String? _lastMapKey;
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isLoading = false;
  Map<String, dynamic>? _navResultData;
  List<Offset> _currentPath = [];

  // Toggle between 3rd-person and 1st-person
  bool _firstPerson = false;

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  /// Loads and decodes the floorplan image.
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

  /// Initializes the camera for preview/capture.
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _isCameraInitialized = false);
        return;
      }
      final controller = CameraController(cameras[0], ResolutionPreset.high, enableAudio: false);
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

  /// Single-tap to capture and upload.
  void _onTapCapture() {
    _captureAndSend();
  }

  /// Captures and sends an image to backend, then processes the navigation result.
  Future<void> _captureAndSend() async {
    if (_isLoading || !_isCameraInitialized || _cameraController == null) return;
    setState(() => _isLoading = true);
    try {
      final file = await _cameraController!.takePicture();
      final rawBytes = await file.readAsBytes();
      final fixedBytes = await fixImageOrientation(rawBytes);
      final result = await ApiService.unavNavigation(fixedBytes, 'query.jpg');
      if (!mounted) return;
      if (result['success'] != true) {
        await _handleError(result['error']?.toString() ?? 'Unknown error');
        return;
      }
      await _processNavResult(result);
    } catch (_) {
      await _handleError(null);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleError(String? err) async {
    final lang = context.read<SettingsProvider>().languageCode;
    String msg = err?.isNotEmpty == true
      ? err!
      : lang == 'zh' ? '网络或内部错误。' : lang == 'th' ? 'เกิดข้อผิดพลาดของระบบหรือเครือข่าย' : 'Network or internal error.';
    await TTSService.setLanguage(lang);
    await TTSService.speak(msg);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  Future<Uint8List> fixImageOrientation(Uint8List imageBytes) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    const maxSide = 640;
    int newW, newH;
    if (w >= h) { newW = maxSide; newH = (h * maxSide / w).round(); }
    else { newH = maxSide; newW = (w * maxSide / h).round(); }
    return await FlutterImageCompress.compressWithList(
      imageBytes,
      format: CompressFormat.jpeg,
      quality: 99,
      minWidth: newW,
      minHeight: newH,
      autoCorrectionAngle: true,
    );
  }
  
  /// Processes the navigation result using structured commands with tags and metadata.
  Future<void> _processNavResult(Map<String, dynamic> result) async {
    // Extract path keys and coordinates for floor segmentation
    final pathKeys = result['result']?['path_keys'] ?? [];
    final pathCoords = result['result']?['path_coords'] ?? [];
    final floorSegs = splitPathByFloor(pathKeys, pathCoords);

    // Parse command list from backend result; ensure each is a map
    final List<dynamic> cmdsRaw = result['cmds'] ?? [];
    final List<Map<String, dynamic>> cmds = cmdsRaw
        .whereType<Map<String, dynamic>>()
        .cast<Map<String, dynamic>>()
        .toList();

    if (cmds.isNotEmpty) {
      // Set TTS language to current user setting
      final lang = context.read<SettingsProvider>().languageCode;
      await TTSService.setLanguage(lang);

      // Extract the current group of navigation commands to be spoken
      final group = _extractCurrentCommandGroup(cmds);

      // Only speak the 'text' field from each command
      final groupTexts = group
          .map((cmd) => cmd['text'] as String? ?? '')
          .where((t) => t.isNotEmpty)
          .toList();
      TTSService.speakSequentially(groupTexts);
    }

    // Determine if the map (floor/building) has changed; reload if needed
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

  /// Extracts the current group of navigation commands for sequential TTS playback.
  ///
  /// Logic:
  /// - Collect commands up to and including the first 'forward' or 'forward_door' command.
  /// - If such a command exists, also append any following non-turn/non-forward instructions.
  /// - Designed for step-by-step navigation guidance.
  ///
  /// [cmds] - List of structured command maps from the backend.
  /// Returns a sublist of commands to be spoken in this navigation step.
  List<Map<String, dynamic>> _extractCurrentCommandGroup(List<Map<String, dynamic>> cmds) {
    if (cmds.isEmpty) return [];
    final result = <Map<String, dynamic>>[];
    bool foundForward = false;
    int i = 0;
    // Collect commands up to and including the first 'forward' command
    for (; i < cmds.length; ++i) {
      result.add(cmds[i]);
      if (_isForwardTag(cmds[i]['tag'])) {
        foundForward = true;
        i++;
        break;
      }
    }
    if (!foundForward) return result;
    // Add any following annotation or landmark (stop at next turn or forward)
    for (; i < cmds.length; ++i) {
      final tag = cmds[i]['tag'] as String? ?? '';
      if (_isTurnTag(tag) || _isForwardTag(tag)) break;
      result.add(cmds[i]);
    }
    return result;
  }

  /// Checks if the command tag represents a forward movement.
  bool _isForwardTag(String? tag) {
    return tag == 'forward' || tag == 'forward_door';
  }

  /// Checks if the command tag represents a turn or U-turn.
  bool _isTurnTag(String? tag) {
    return tag == 'turn' || tag == 'u_turn';
  }


  Widget _buildCameraPreview(Orientation orientation) {
    if (!_isCameraInitialized || _cameraController == null) {
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
              // Floorplan + path painter
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

              // Camera preview
              Positioned(
                bottom: 24,
                right: 16,
                child: _buildCameraPreview(orientation),
              ),

              // Avatar toggle button
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: GestureDetector(
                    onTap: () => setState(() => _firstPerson = !_firstPerson),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundImage: Provider.of<SettingsProvider>(context, listen: false)
                                  .avatarUrl !=
                              null
                          ? NetworkImage(
                              Provider.of<SettingsProvider>(context, listen: false)
                                  .avatarUrl!)
                          : const AssetImage('assets/avatar_placeholder.png')
                              as ImageProvider,
                    ),
                  ),
                ),
              ),

              // Loading indicator
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),

              // Back button
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, size: 32, color: Colors.white),
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
