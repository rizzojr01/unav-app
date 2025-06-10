import 'dart:typed_data';
import 'dart:ui' as ui;
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

/// NavigationScreen displays the indoor navigation UI with floorplan, navigation path,
/// floating camera preview for localization input, and a persistent avatar/logout button in the top right.
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

  /// Handle app lifecycle for camera safety
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  /// Fetch the floorplan image and decode it for CustomPainter overlay.
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

  /// Initialize the camera for preview and localization capture.
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

  /// Fix image orientation and compress for server upload.
  Future<Uint8List> _fixImageOrientation(Uint8List imageBytes) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final originalWidth = frame.image.width;
    final originalHeight = frame.image.height;
    int maxSide = 640;
    int newWidth, newHeight;
    if (originalWidth >= originalHeight) {
      newWidth = maxSide;
      newHeight = (originalHeight * maxSide / originalWidth).round();
    } else {
      newHeight = maxSide;
      newWidth = (originalWidth * maxSide / originalHeight).round();
    }
    final result = await FlutterImageCompress.compressWithList(
      imageBytes,
      format: CompressFormat.jpeg,
      quality: 99,
      minWidth: newWidth,
      minHeight: newHeight,
      autoCorrectionAngle: true,
    );
    return result;
  }

  /// Camera capture, upload to backend, parse navigation result, update path and trigger TTS for current step.
  Future<void> _captureAndSend() async {
    if (_isLoading || !_isCameraInitialized || _cameraController == null) return;
    setState(() => _isLoading = true);

    try {
      final file = await _cameraController!.takePicture();
      final rawBytes = await file.readAsBytes();
      final fixedBytes = await _fixImageOrientation(rawBytes);
      final result = await ApiService.unavNavigation(fixedBytes, "query.jpg");

      if (!mounted) return;

      // Handle error
      if (result.containsKey('error')) {
        final lang = context.read<SettingsProvider>().languageCode;
        await TTSService.setLanguage(lang);
        String msg = result['error']?.toString() ?? "Unknown error.";
        if (lang == "zh") {
          if (msg == "Localization failed, no pose found.") msg = "定位失败，未找到位姿。";
        } else if (lang == "th") {
          if (msg == "Localization failed, no pose found.") msg = "ไม่พบตำแหน่งของคุณ";
        }
        await TTSService.speak(msg);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red),
          );
        }
        return;
      }

      // Parse result
      final List<dynamic> pathKeys = result["result"]?["path_keys"] ?? [];
      final List<dynamic> pathCoords = result["result"]?["path_coords"] ?? [];
      final floorSegs = splitPathByFloor(pathKeys, pathCoords);

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

  /// Determines if a command string is a "turn" command.
  bool _isTurnCmd(String cmd, String lang) {
    final keys = turnKeywords[lang] ?? turnKeywords['en']!;
    return keys.any((k) => cmd.contains(k));
  }

  /// Determines if a command string is a "forward" command.
  bool _isForwardCmd(String cmd, String lang) {
    final keys = forwardKeywords[lang] ?? forwardKeywords['en']!;
    return keys.any((k) => cmd.contains(k));
  }

  /// Extract a group of navigation commands for TTS (see your logic above).
  List<String> _extractCurrentCommandGroup(List<String> cmds) {
    if (cmds.isEmpty) return [];
    final lang = context.read<SettingsProvider>().languageCode;
    final result = <String>[];
    bool foundForward = false;
    int i = 0;
    for (; i < cmds.length; ++i) {
      result.add(cmds[i]);
      if (_isForwardCmd(cmds[i].toLowerCase(), lang)) {
        foundForward = true;
        i++;
        break;
      }
    }
    if (!foundForward) return result;
    for (; i < cmds.length; ++i) {
      if (_isTurnCmd(cmds[i].toLowerCase(), lang) || _isForwardCmd(cmds[i].toLowerCase(), lang)) break;
      result.add(cmds[i]);
    }
    return result;
  }

  /// Build the floating camera preview widget (bottom right corner)
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
    if (previewSize == null) {
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
    final double aspectRatio = orientation == Orientation.portrait
        ? previewSize.height / previewSize.width
        : previewSize.width / previewSize.height;
    final double base = 200.0;
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

  /// Build the user avatar with logout button for top right corner.
  Widget _buildTopBar() {
    final settingsProvider = context.watch<SettingsProvider>();
    final avatarFile = settingsProvider.avatarFile;
    final avatarUrl = settingsProvider.avatarUrl;
    return SafeArea(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.black87, size: 28),
            tooltip: "Logout",
            onPressed: () async {
              await ApiService.logout();
              if (context.mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0, top: 6),
            child: CircleAvatar(
              radius: 24,
              backgroundImage: avatarFile != null
                  ? FileImage(avatarFile)
                  : (avatarUrl != null && avatarUrl.isNotEmpty
                      ? NetworkImage(avatarUrl) as ImageProvider
                      : null),
              child: (avatarFile == null && (avatarUrl == null || avatarUrl.isEmpty))
                  ? const Icon(Icons.person, color: Colors.white, size: 30)
                  : null,
              backgroundColor: Colors.blueGrey[200],
            ),
          ),
        ],
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
          final double canvasWidth = constraints.maxWidth;
          final double canvasHeight = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Background floorplan image with path overlay
              GestureDetector(
                onTap: _captureAndSend,
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

              // Floating camera preview in bottom right
              Positioned(
                bottom: 24,
                right: 16,
                child: _buildCameraPreview(orientation),
              ),

              // Loading indicator at the center
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),

              // Top right: Avatar and Logout
              Positioned(
                top: 0,
                right: 0,
                left: 0,
                child: _buildTopBar(),
              ),

              // Top left: Back button
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

/// Helper: Split path by floor (stub, fill in your logic)
Map<String, List<Offset>> splitPathByFloor(List<dynamic> pathKeys, List<dynamic> pathCoords) {
  // TODO: Implement actual logic if needed; placeholder:
  return {
    if (pathKeys.isNotEmpty)
      pathKeys.take(1).join('|'): pathCoords.map<Offset>((c) => Offset(c[0].toDouble(), c[1].toDouble())).toList(),
  };
}
