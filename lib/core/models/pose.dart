class Pose {
  final double x;
  final double y;
  final double z;
  final double heading;
  final double confidence;
  final DateTime timestamp;
  final double? worldX;
  final double? worldY;
  final double? worldZ;
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
    this.worldX,
    this.worldY,
    this.worldZ,
    this.gravityX,
    this.gravityY,
    this.gravityZ,
    this.interfaceRotationDeg = 0,
  });
}
