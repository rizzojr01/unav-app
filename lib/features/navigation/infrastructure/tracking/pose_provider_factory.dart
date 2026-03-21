import 'dart:io';

import '../../../../core/interfaces/pose_provider.dart';
import 'ar_pose_provider.dart';
import 'ar_session_adapter.dart';
import 'mock_route_pose_provider.dart';
import 'native_ar_session_adapter.dart';
import 'stub_ar_session_adapter.dart';

enum PoseProviderMode {
  mockRoute,
  nativeAr,
}

class PoseProviderBundle {
  final PoseProvider provider;
  final MockRoutePoseProvider? mockRouteProvider;
  final ArSessionAdapter? arSessionAdapter;
  final PoseProviderMode mode;

  const PoseProviderBundle({
    required this.provider,
    required this.mode,
    this.mockRouteProvider,
    this.arSessionAdapter,
  });

  Future<void> dispose() async {
    if (mockRouteProvider != null) {
      await mockRouteProvider!.dispose();
    }
    if (arSessionAdapter case final StubArSessionAdapter stub) {
      await stub.dispose();
    }
  }
}

class PoseProviderFactory {
  const PoseProviderFactory();

  PoseProviderBundle create({
    PoseProviderMode preferredMode = PoseProviderMode.mockRoute,
  }) {
    if (preferredMode == PoseProviderMode.nativeAr) {
      final adapter = _createAdapterForPlatform();
      return PoseProviderBundle(
        provider: ArPoseProvider(adapter: adapter),
        arSessionAdapter: adapter,
        mode: PoseProviderMode.nativeAr,
      );
    }

    final mock = MockRoutePoseProvider();
    return PoseProviderBundle(
      provider: mock,
      mockRouteProvider: mock,
      mode: PoseProviderMode.mockRoute,
    );
  }

  ArSessionAdapter _createAdapterForPlatform() {
    if (Platform.isIOS) {
      return const NativeArSessionAdapter(backend: ArTrackingBackend.iosArKit);
    }
    if (Platform.isAndroid) {
      return const NativeArSessionAdapter(backend: ArTrackingBackend.androidArCore);
    }
    return StubArSessionAdapter(ArTrackingBackend.unsupported);
  }
}
