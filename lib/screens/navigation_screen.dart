// navigation_screen.dart

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../api/api_service.dart';
import '../widgets/floorplan_path_painter.dart';

/// NavigationScreen overlays the navigation path over the floorplan,
/// and displays a floating camera preview for localization input.
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
  List<Offset> _currentPath = [];       // Path coordinates for the current floor only

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

  /// Loads the floorplan image from backend.
  Future<void> _fetchFloorplan() async {
    try {
      // 若 API 支持按楼层取图片，可以直接用 currMapKey
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

  /// Captures an image, sends it to the backend, and updates navigation path for the current floor.
  Future<void> _captureAndSend() async {
    if (_isLoading || !_isCameraInitialized || _cameraController == null) return;
    setState(() => _isLoading = true);
    try {
      final file = await _cameraController!.takePicture();
      final bytes = await file.readAsBytes();
      final result = await ApiService.unavNavigation(bytes, "query.jpg");
      if (mounted) {
        // Parse all path segments by floor.
        final List<dynamic> pathKeys = result["result"]?["path_keys"] ?? [];
        final List<dynamic> pathCoords = result["result"]?["path_coords"] ?? [];
        final floorSegs = splitPathByFloor(pathKeys, pathCoords);

        // Use the best_map_key from server as the current floor key.
        // It may be a List or a Tuple encoded as List.
        final dynamic bestMapKey = result["best_map_key"];
        final String currMapKey = (bestMapKey as List).take(3).join('|');
        // Only fetch floorplan if mapKey changed
        if (currMapKey != _lastMapKey) {
          await _fetchFloorplan();
          _lastMapKey = currMapKey;
        }

        setState(() {
          _navResultData = result;
          _currentPath = floorSegs[currMapKey] ?? [];
        });
      }
      // Optionally: handle navigation instructions (TTS or visual) here.
    } catch (e) {
      // Optionally: show error message or retry.
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
                // 1. 包裹 floorplan image + path painter 区域
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

                // 2. ---- Camera preview floating window ----
                Positioned(
                  bottom: 24,
                  right: 16,
                  child: _buildCameraPreview(orientation),
                ),

                // 3. ---- Loading indicator ----
                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),

                // 4. ---- Back button ----
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