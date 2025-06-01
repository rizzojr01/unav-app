import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../api/api_service.dart';
// import '../services/tts_service.dart'; // Uncomment if using TTS

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

class _NavigationScreenState extends State<NavigationScreen> {
  Uint8List? _floorplanBytes;
  String? _floorplanError;
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isLoading = false;
  String? _navResult; // Navigation result text

  @override
  void initState() {
    super.initState();
    _fetchFloorplan();
    _initCamera();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  /// Load floorplan image from server
  Future<void> _fetchFloorplan() async {
    try {
      final fp = await ApiService.getFloorplan();
      setState(() {
        _floorplanBytes = fp;
        _floorplanError = fp == null ? "error" : null;
      });
    } catch (e) {
      setState(() {
        _floorplanError = "error";
      });
    }
  }

  /// Initialize the camera
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _isCameraInitialized = false;
        });
        return;
      }
      final CameraController cameraController = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await cameraController.initialize();
      setState(() {
        _cameraController = cameraController;
        _isCameraInitialized = true;
      });
    } catch (e) {
      setState(() {
        _isCameraInitialized = false;
      });
    }
  }

  /// Capture an image from camera, send to server for navigation
  Future<void> _captureAndSend() async {
    if (_isLoading) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      setState(() {
        _navResult = "Camera not available.";
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _navResult = null;
    });
    try {
      final XFile imageFile = await _cameraController!.takePicture();
      final bytes = await imageFile.readAsBytes();
      final result = await ApiService.unavNavigation(bytes, "query.jpg");
      setState(() {
        _navResult = _formatJson(result);
        _isLoading = false;
      });
      // 可选：语音播报导航指令
      // if (result.containsKey('commands')) {
      //   TTSService.speak(result['commands'].join('. '));
      // }
    } catch (e) {
      setState(() {
        _navResult = "Navigation failed: $e";
        _isLoading = false;
      });
    }
  }

  /// Format JSON for readable display
  String _formatJson(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (e) {
      return data.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    // --- Floorplan Widget (with error fallback) ---
    Widget floorplanWidget;
    if (_floorplanError == "error" || _floorplanBytes == null) {
      floorplanWidget = GestureDetector(
        onTap: _captureAndSend,
        child: Container(
          color: Colors.grey[300],
          width: double.infinity,
          height: 240,
          alignment: Alignment.center,
          child: Text(
            "Please touch the screen to take an image.",
            style: TextStyle(fontSize: 20, color: Colors.black54),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      floorplanWidget = GestureDetector(
        onTap: _captureAndSend,
        child: Image.memory(
          _floorplanBytes!,
          width: double.infinity,
          height: 240,
          fit: BoxFit.contain,
        ),
      );
    }

    // --- Camera Preview Widget ---
    Widget cameraPreviewWidget = Container(
      width: 120,
      height: 160,
      color: Colors.black,
      child: _isCameraInitialized && _cameraController != null
          ? GestureDetector(
              onTap: _captureAndSend,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CameraPreview(_cameraController!),
              ),
            )
          : Center(
              child: Text(
                "Camera not ready",
                style: TextStyle(color: Colors.white),
              ),
            ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text("Navigation"),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Floorplan
              Center(child: floorplanWidget),
              const SizedBox(height: 16),
              // Current Navigation Context
              _navContext(),
              const SizedBox(height: 20),
              // Navigation Result
              if (_isLoading)
                const Center(child: CircularProgressIndicator())
              else if (_navResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12.0),
                  child: SelectableText(
                    _navResult!,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
          // --- Camera preview (bottom right) ---
          Positioned(
            bottom: 30,
            right: 16,
            child: cameraPreviewWidget,
          ),
        ],
      ),
    );
  }

  /// Display navigation context
  Widget _navContext() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Place: ${widget.selectedPlaceName}"),
        Text("Building: ${widget.selectedBuildingName}"),
        Text("Floor: ${widget.selectedFloorName}"),
        Text("Destination: ${widget.selectedDestinationName}"),
      ],
    );
  }
}
