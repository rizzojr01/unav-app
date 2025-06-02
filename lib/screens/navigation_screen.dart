import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../api/api_service.dart';

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
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isLoading = false;

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

  // 当 App 进入后台/恢复时，要销毁或重建相机资源
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  /// 从后端拉取 Floorplan（字节流）
  Future<void> _fetchFloorplan() async {
    try {
      final fp = await ApiService.getFloorplan();
      if (mounted) {
        setState(() {
          _floorplanBytes = fp;
        });
      }
    } catch (e) {
      // 如果拉取失败，可以显示错误占位，这里暂时不处理
      if (mounted) {
        setState(() {
          _floorplanBytes = null;
        });
      }
    }
  }

  /// 初始化相机，用于预览和拍照
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
      if (mounted) {
        setState(() {
          _isCameraInitialized = false;
        });
      }
    }
  }

  /// 拍照并上传到 server 进行导航
  Future<void> _captureAndSend() async {
    if (_isLoading || !_isCameraInitialized || _cameraController == null) return;
    setState(() => _isLoading = true);
    try {
      final file = await _cameraController!.takePicture();
      final bytes = await file.readAsBytes();
      await ApiService.unavNavigation(bytes, "query.jpg");
      // 如果需要 TTS 或者可视化处理导航结果，在这里处理即可
    } catch (e) {
      // 打印或忽略异常
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// 返回一个用于悬浮在右下角的“Camera Preview” widget
  ///
  /// 1. 如果是 portrait（竖屏），需要旋转 90°，并构造一个 “高>宽” 的框
  /// 2. 如果是 landscape（横屏），直接使用原始横向比例即可
  Widget _buildCameraPreview(Orientation orientation) {
    if (!_isCameraInitialized || _cameraController == null) {
      // 未就绪时显示占位
      if (orientation == Orientation.portrait) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: Colors.black38,
            width: 120,
            height: 160,
            child: const Center(
              child: Icon(Icons.videocam_off, color: Colors.white),
            ),
          ),
        );
      } else {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: Colors.black38,
            width: 160,
            height: 120,
            child: const Center(
              child: Icon(Icons.videocam_off, color: Colors.white),
            ),
          ),
        );
      }
    }

    // 已初始化：获取相机实际预览的宽高比（一般为 4/3 或者 16/9 等）
    final previewSize = _cameraController!.value.previewSize;
    if (previewSize == null) {
      // 万一为空，仍然给一个默认占位
      if (orientation == Orientation.portrait) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: Colors.black38,
            width: 120,
            height: 160,
            child: const Center(
              child: Icon(Icons.videocam_off, color: Colors.white),
            ),
          ),
        );
      } else {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: Colors.black38,
            width: 160,
            height: 120,
            child: const Center(
              child: Icon(Icons.videocam_off, color: Colors.white),
            ),
          ),
        );
      }
    }

    // 原始预览比例 (宽 / 高)，通常 sensor 默认是横向
    final double rawAspectRatio = previewSize.width / previewSize.height;

    if (orientation == Orientation.portrait) {
      final double H = 200; // 竖屏窗口高度
      final double aspectRatio = previewSize.height / previewSize.width; // 注意这里反过来
      final double origWidth = H * aspectRatio; // 竖屏下: 宽=高*竖直方向的宽高比
      final double origHeight = H;

      return GestureDetector(
        onTap: _captureAndSend,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: origWidth,
            height: origHeight,
            color: Colors.black,
            child: CameraPreview(_cameraController!),
          ),
        ),
      );
    } else {
      // -------- 横屏：直接使用横向预览比例 --------
      // 选一个固定“窗口宽度”，比如 200。预览画面原本就是横向，所以：
      // previewWidth = W, previewHeight = W / rawAspectRatio
      final double W = 200;
      final double origWidth = W;
      final double origHeight = W / rawAspectRatio;

      return GestureDetector(
        onTap: _captureAndSend,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: origWidth,
            height: origHeight,
            color: Colors.black,
            child: CameraPreview(_cameraController!),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ---------------- Floorplan（底部背景） ----------------
          if (_floorplanBytes != null)
            Image.memory(
              _floorplanBytes!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            )
          else
            Container(color: Colors.grey[200]),

          // ------------- Camera Preview 悬浮在右下角 -------------
          Positioned(
            bottom: 24,
            right: 16,
            child: _buildCameraPreview(orientation),
          ),

          // -------------------- Loading 指示器 --------------------
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // -------------------- 返回按钮 --------------------
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
      ),
    );
  }
}
