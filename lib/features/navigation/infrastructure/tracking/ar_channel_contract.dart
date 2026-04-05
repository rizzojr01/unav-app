class ArChannelContract {
  static const String methodChannel = 'unav/tracking/ar_method';
  static const String eventChannel = 'unav/tracking/ar_pose_stream';

  static const String startSessionMethod = 'startSession';
  static const String stopSessionMethod = 'stopSession';
  static const String getCapabilitiesMethod = 'getCapabilities';
  static const String captureCurrentFrameMethod = 'captureCurrentFrame';
  // Returns a dict with JPEG bytes + contemporaneous ARFrame pose + arTimestamp.
  // Used by TrialRecorder to align VPR queries with the ARKit pose stream.
  static const String captureCurrentFrameWithPoseMethod =
      'captureCurrentFrameWithPose';
  static const String updateOverlayMethod = 'updateOverlay';
  static const String clearOverlayMethod = 'clearOverlay';
  static const String previewViewType = 'unav/tracking/ar_preview_view';

  static const String backendKey = 'backend';
  static const String xKey = 'x';
  static const String yKey = 'y';
  static const String zKey = 'z';
  static const String headingKey = 'heading';
  static const String confidenceKey = 'confidence';
  static const String timestampKey = 'timestampMillis';
  // Native ARFrame.timestamp (seconds, CACurrentMediaTime domain). This is
  // what lets us align VPR query captures with a row in the pose ndjson
  // stream: every pose event has an arTimestamp, and every capture returns
  // the same field. Matching them gives sub-frame precision.
  static const String arTimestampKey = 'arTimestamp';
  static const String isSupportedKey = 'isSupported';
  static const String worldXKey = 'worldX';
  static const String worldYKey = 'worldY';
  static const String worldZKey = 'worldZ';
  // Camera orientation as a unit quaternion [qw, qx, qy, qz] in the ARKit
  // world frame. Full-fidelity orientation — downstream code can derive any
  // Euler / rotation-matrix representation without loss.
  static const String quatWKey = 'qw';
  static const String quatXKey = 'qx';
  static const String quatYKey = 'qy';
  static const String quatZKey = 'qz';
  // "normal" | "limited" | "notAvailable"
  static const String trackingStateKey = 'trackingState';
  // Response key carrying the JPEG bytes inside captureCurrentFrameWithPose.
  static const String jpegBytesKey = 'jpegBytes';
  static const String gravityXKey = 'gravityX';
  static const String gravityYKey = 'gravityY';
  static const String gravityZKey = 'gravityZ';
  static const String interfaceRotationDegKey = 'interfaceRotationDeg';
  static const String pathPointsKey = 'pathPoints';
  static const String activePathPointsKey = 'activePathPoints';
  static const String futurePathPointsKey = 'futurePathPoints';
  static const String nextWaypointKey = 'nextWaypoint';
  static const String destinationKey = 'destination';
  static const String waypointPulsePeriodSecKey = 'waypointPulsePeriodSec';
  static const String waypointPulseActiveKey = 'waypointPulseActive';
}
