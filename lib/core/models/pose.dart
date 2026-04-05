class Pose {
  final double x;
  final double y;
  final double z;
  final double heading;
  final double confidence;
  final DateTime timestamp;
  // ARFrame.timestamp in seconds (CACurrentMediaTime domain on iOS). Used to
  // align VPR query captures with rows in the recorded pose ndjson.
  // Null on non-native backends (e.g. mock).
  final double? arTimestamp;
  final double? worldX;
  final double? worldY;
  final double? worldZ;
  // Full camera orientation as a quaternion in the AR world frame. When all
  // four are present, downstream code can losslessly derive any Euler
  // representation. Null on non-native backends.
  final double? qw;
  final double? qx;
  final double? qy;
  final double? qz;
  // "normal" | "limited" | "notAvailable" on iOS. Null elsewhere.
  final String? trackingState;
  final double? gravityX;
  final double? gravityY;
  final double? gravityZ;
  final double interfaceRotationDeg;

  const Pose({
    required this.x,
    required this.y,
    this.z = 0,
    this.heading = 0,
    this.confidence = 1,
    required this.timestamp,
    this.arTimestamp,
    this.worldX,
    this.worldY,
    this.worldZ,
    this.qw,
    this.qx,
    this.qy,
    this.qz,
    this.trackingState,
    this.gravityX,
    this.gravityY,
    this.gravityZ,
    this.interfaceRotationDeg = 0,
  });
}
