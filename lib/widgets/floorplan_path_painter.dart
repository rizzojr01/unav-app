// floorplan_path_painter.dart

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Custom painter for overlaying the navigation path over the floorplan image.
class FloorplanPathPainter extends CustomPainter {
  final List<Offset> pathPoints;        // Path coordinates (floorplan pixels)
  final ui.Image? floorplanImage;       // The decoded floorplan image
  final double? headingAngleDeg;        // Heading angle at path start (degrees, 0 = right, positive = counter-clockwise)
  final double arrowLength;             // Length of direction arrow (in floorplan pixels)
  final Color pathColor;                // Path color
  final double pathWidth;               // Path line width

  const FloorplanPathPainter({
    required this.pathPoints,
    required this.floorplanImage,
    this.headingAngleDeg,
    this.arrowLength = 32.0,
    this.pathColor = Colors.lime,
    this.pathWidth = 6.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Defensive: If floorplan not ready, nothing to draw.
    if (floorplanImage == null) return;

    final double imgW = floorplanImage!.width.toDouble();
    final double imgH = floorplanImage!.height.toDouble();
    final double canvasW = size.width;
    final double canvasH = size.height;

    double clampSafe(double value, double min, double max) {
      if (min > max) {
        // 如果 min 比 max 大，直接返回 max（此时 offset 应该是0）
        return max;
      }
      if (value.isNaN || value.isInfinite) return max;
      return value.clamp(min, max);
    }

    // Always show the floorplan background, even if no path.
    if (pathPoints.isEmpty) {
      _drawFloorplan(canvas, imgW, imgH, canvasW, canvasH, Offset.zero, 1.0);
      return;
    }

    // 1. Calculate scale for BoxFit.cover (no distortion, full coverage)
    final double scale = math.max(canvasW / imgW, canvasH / imgH);
    final double displayW = imgW * scale;
    final double displayH = imgH * scale;

    // 2. Center the current position (first path point) as much as possible
    final Offset cur = pathPoints[0];
    final Offset canvasCenter = Offset(canvasW / 2, canvasH / 2);
    Offset offset = canvasCenter - Offset(cur.dx * scale, cur.dy * scale);

    // 3. Prevent the floorplan from exceeding canvas bounds (clamp)
    double minOffsetX = canvasW - displayW;
    double maxOffsetX = 0.0;
    double minOffsetY = canvasH - displayH;
    double maxOffsetY = 0.0;
    offset = Offset(
        clampSafe(offset.dx, minOffsetX, maxOffsetX),
        clampSafe(offset.dy, minOffsetY, maxOffsetY),
    );

    // 4. Draw the cropped floorplan region that appears in the current canvas
    final Rect srcRect = Rect.fromLTWH(
      (-offset.dx) / scale,
      (-offset.dy) / scale,
      canvasW / scale,
      canvasH / scale,
    ).intersect(Rect.fromLTWH(0, 0, imgW, imgH)); // Clip to floorplan image

    final Rect dstRect = Rect.fromLTWH(0, 0, canvasW, canvasH);
    canvas.drawImageRect(floorplanImage!, srcRect, dstRect, Paint());

    // 5. Map path points to canvas coordinates (after scale and offset)
    List<Offset> mapped = pathPoints
        .map((pt) => Offset(
              (pt.dx * scale) + offset.dx,
              (pt.dy * scale) + offset.dy,
            ))
        .toList();

    // 6. Draw the navigation path
    if (mapped.length > 1) {
      final Paint pathPaint = Paint()
        ..color = pathColor
        ..strokeWidth = pathWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final Path path = Path()..moveTo(mapped[0].dx, mapped[0].dy);
      for (int i = 1; i < mapped.length; ++i) {
        path.lineTo(mapped[i].dx, mapped[i].dy);
      }
      canvas.drawPath(path, pathPaint);

      // Highlight start/endpoints
      canvas.drawCircle(mapped.first, pathWidth * 1.3, Paint()..color = Colors.blue);
      canvas.drawCircle(mapped.last, pathWidth * 1.3, Paint()..color = Colors.red);
    }

    // 7. Draw heading arrow at the start, if headingAngleDeg is provided
    if (headingAngleDeg != null && mapped.isNotEmpty) {
      // The arrow is drawn in the canvas coordinate system.
      final Offset startPt = mapped.first;

      // headingAngleDeg: 0=right, 90=down, -90=up, 180/-180=left (match server definition)
      // Flutter's coordinate: +x right, +y down, angle in radians
      final double theta = headingAngleDeg! * math.pi / 180.0;

      // Arrow tip point
      final Offset arrowTip = startPt + Offset(
        arrowLength * math.cos(theta),
        arrowLength * math.sin(theta),
      );

      // Draw main arrow shaft
      final Paint arrowPaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = pathWidth * 0.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(startPt, arrowTip, arrowPaint);

      // Draw arrow head (two side wings)
      const double headLen = 12.0;
      const double headAngle = 25 * math.pi / 180.0;
      final Offset headLeft = arrowTip +
          Offset(
            -headLen * math.cos(theta - headAngle),
            -headLen * math.sin(theta - headAngle),
          );
      final Offset headRight = arrowTip +
          Offset(
            -headLen * math.cos(theta + headAngle),
            -headLen * math.sin(theta + headAngle),
          );
      canvas.drawLine(arrowTip, headLeft, arrowPaint);
      canvas.drawLine(arrowTip, headRight, arrowPaint);
    }
  }

  // Draw floorplan only (used when pathPoints is empty)
  void _drawFloorplan(Canvas canvas, double imgW, double imgH, double canvasW, double canvasH, Offset offset, double scale) {
    final double displayW = imgW * scale;
    final double displayH = imgH * scale;
    final Rect srcRect = Rect.fromLTWH(0, 0, imgW, imgH);
    final Rect dstRect = Rect.fromLTWH(
      (canvasW - displayW) / 2,
      (canvasH - displayH) / 2,
      displayW,
      displayH,
    );
    canvas.drawImageRect(floorplanImage!, srcRect, dstRect, Paint());
  }

  @override
  bool shouldRepaint(covariant FloorplanPathPainter oldDelegate) =>
      oldDelegate.pathPoints != pathPoints ||
      oldDelegate.floorplanImage != floorplanImage ||
      oldDelegate.headingAngleDeg != headingAngleDeg ||
      oldDelegate.pathColor != pathColor ||
      oldDelegate.pathWidth != pathWidth;
}

/// Parses the path coordinates (pixel space) from server navigation result.
/// Returns a list of Offset points.
List<Offset> parsePathCoordsFromResult(Map<String, dynamic>? navResultData) {
  if (navResultData == null) return [];
  final result = navResultData["result"];
  if (result == null || result["path_coords"] == null) return [];
  final coords = result["path_coords"] as List<dynamic>;
  return coords
      .map<Offset>((pt) => Offset(
          (pt[0] as num).toDouble(),
          (pt[1] as num).toDouble()))
      .toList();
}

/// Splits the global navigation path into segments by floor.
/// Each floor segment is keyed by a List<String> [place, building, floor].
Map<String, List<Offset>> splitPathByFloor(
    List<dynamic> pathKeys,
    List<dynamic> pathCoords,
) {
  final Map<String, List<Offset>> floorSegs = {};
  Offset? startCoord;
  bool startInserted = false;

  for (int i = 0; i < pathKeys.length; ++i) {
    final dynamic key = pathKeys[i];
    final dynamic coord = pathCoords[i];

    if (key == "VIRT") {
      startCoord = Offset((coord[0] as num).toDouble(), (coord[1] as num).toDouble());
      continue;
    }

    if (key is List && key.length >= 3) {
      final String floorKey = "${key[0]}|${key[1]}|${key[2]}";
      floorSegs.putIfAbsent(floorKey, () => []);
      if (startCoord != null && !startInserted) {
        floorSegs[floorKey]!.add(startCoord);
        startInserted = true;
      }
      floorSegs[floorKey]!.add(Offset((coord[0] as num).toDouble(), (coord[1] as num).toDouble()));
    }
  }
  return floorSegs;
}