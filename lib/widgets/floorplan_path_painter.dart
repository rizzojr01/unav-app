import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Custom painter for overlaying a navigation path on the floorplan image.
/// This version is simplified to a fixed static overview as per initial requirements.
class FloorplanPathPainter extends CustomPainter {
  final List<Offset> pathPoints;
  final ui.Image? floorplanImage;
  final double? headingAngleDeg;
  final double arrowLength;
  final Color pathColor;
  final double pathWidth;
  final bool firstPersonView;

  const FloorplanPathPainter({
    required this.pathPoints,
    required this.floorplanImage,
    this.headingAngleDeg,
    this.arrowLength = 32.0,
    this.pathColor = Colors.lime,
    this.pathWidth = 6.0,
    this.firstPersonView = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (floorplanImage == null) return;

    final double imgW = floorplanImage!.width.toDouble();
    final double imgH = floorplanImage!.height.toDouble();
    final double canvasW = size.width;
    final double canvasH = size.height;

    double clampSafe(double value, double min, double max) {
      if (min > max) return max;
      if (value.isNaN || value.isInfinite) return max;
      return value.clamp(min, max);
    }

    // --------- Static Overview View ----------
    if (pathPoints.isEmpty) {
      _drawFloorplan(canvas, imgW, imgH, canvasW, canvasH, Offset.zero, 1.0);
      return;
    }

    final double scale = math.max(canvasW / imgW, canvasH / imgH);
    final double displayW = imgW * scale;
    final double displayH = imgH * scale;

    final Offset cur = pathPoints[0];
    final Offset canvasCenter = Offset(canvasW / 2, canvasH / 2);
    Offset offset = canvasCenter - Offset(cur.dx * scale, cur.dy * scale);

    double minOffsetX = canvasW - displayW;
    double maxOffsetX = 0.0;
    double minOffsetY = canvasH - displayH;
    double maxOffsetY = 0.0;
    offset = Offset(
      clampSafe(offset.dx, minOffsetX, maxOffsetX),
      clampSafe(offset.dy, minOffsetY, maxOffsetY),
    );

    final Rect srcRect = Rect.fromLTWH(
      (-offset.dx) / scale,
      (-offset.dy) / scale,
      canvasW / scale,
      canvasH / scale,
    ).intersect(Rect.fromLTWH(0, 0, imgW, imgH));
    final Rect dstRect = Rect.fromLTWH(0, 0, canvasW, canvasH);
    
    // --------- First-person view (rotated, centered on current location) ----------
    if (firstPersonView && headingAngleDeg != null && pathPoints.isNotEmpty) {
      final double angleRad = -(headingAngleDeg! + 90) * math.pi / 180.0;
      final double scaleFactor = 1.5;
      final Offset cur = pathPoints[0];

      canvas.save();
      canvas.translate(canvasW / 2, canvasH / 2);
      canvas.rotate(angleRad);
      canvas.scale(scaleFactor);
      canvas.translate(-cur.dx, -cur.dy);

      // Draw floorplan image in floorplan coordinates
      canvas.drawImage(floorplanImage!, Offset.zero, Paint());

      // Draw path over floorplan
      if (pathPoints.length > 1) {
        final Paint pathPaint = Paint()
          ..color = pathColor
          ..strokeWidth = pathWidth / scaleFactor
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

        final Path path = Path()..moveTo(pathPoints[0].dx, pathPoints[0].dy);
        for (int i = 1; i < pathPoints.length; ++i) {
          path.lineTo(pathPoints[i].dx, pathPoints[i].dy);
        }
        canvas.drawPath(path, pathPaint);
        canvas.drawCircle(pathPoints.first, pathWidth * 1.3 / scaleFactor, Paint()..color = Colors.blue);
        canvas.drawCircle(pathPoints.last, pathWidth * 1.3 / scaleFactor, Paint()..color = Colors.red);
      }

      // Draw heading arrow from current position
      if (headingAngleDeg != null && pathPoints.isNotEmpty) {
        final Offset startPt = pathPoints.first;
        final double theta = headingAngleDeg! * math.pi / 180.0;
        final Offset arrowTip = startPt + Offset(
          arrowLength * math.cos(theta),
          arrowLength * math.sin(theta),
        );
        final Paint arrowPaint = Paint()
          ..color = Colors.blue
          ..strokeWidth = pathWidth * 0.8 / scaleFactor
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(startPt, arrowTip, arrowPaint);

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
      canvas.restore();
      return;
    }

    canvas.drawImageRect(floorplanImage!, srcRect, dstRect, Paint());

    // Transform path points for display
    List<Offset> mapped = pathPoints
        .map(
          (pt) =>
              Offset((pt.dx * scale) + offset.dx, (pt.dy * scale) + offset.dy),
        )
        .toList();

    // Draw path and endpoints
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
      canvas.drawCircle(
        mapped.first,
        pathWidth * 1.3,
        Paint()..color = Colors.blue,
      );
      canvas.drawCircle(
        mapped.last,
        pathWidth * 1.3,
        Paint()..color = Colors.red,
      );
    }

    // Draw heading arrow from current position
    if (headingAngleDeg != null && mapped.isNotEmpty) {
      final Offset startPt = mapped.first;
      // Heading logic: 0 = East, rotates clockwise (90=South)
      final double theta = headingAngleDeg! * math.pi / 180.0;
      final Offset arrowTip =
          startPt +
          Offset(arrowLength * math.cos(theta), arrowLength * math.sin(theta));
      final Paint arrowPaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = pathWidth * 0.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(startPt, arrowTip, arrowPaint);

      const double headLen = 12.0;
      const double headAngle = 25 * math.pi / 180.0;
      final Offset headLeft =
          arrowTip +
          Offset(
            -headLen * math.cos(theta - headAngle),
            -headLen * math.sin(theta - headAngle),
          );
      final Offset headRight =
          arrowTip +
          Offset(
            -headLen * math.cos(theta + headAngle),
            -headLen * math.sin(theta + headAngle),
          );
      canvas.drawLine(arrowTip, headLeft, arrowPaint);
      canvas.drawLine(arrowTip, headRight, arrowPaint);
    }
  }

  // Draws the floorplan image centered on the canvas (used when no path points).
  void _drawFloorplan(
    Canvas canvas,
    double imgW,
    double imgH,
    double canvasW,
    double canvasH,
    Offset offset,
    double scale,
  ) {
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
      oldDelegate.pathWidth != pathWidth ||
      oldDelegate.firstPersonView != firstPersonView;
}

/// Parses path coordinates (in pixel space) from the navigation result.
List<Offset> parsePathCoordsFromResult(Map<String, dynamic>? navResultData) {
  if (navResultData == null) return [];
  final result = navResultData["result"];
  if (result == null || result["path_coords"] == null) return [];
  final coords = result["path_coords"] as List<dynamic>;
  return coords
      .map<Offset>(
        (pt) => Offset((pt[0] as num).toDouble(), (pt[1] as num).toDouble()),
      )
      .toList();
}

/// Extracts the current pose in floorplan pixel coordinates when available.
Offset? parseFloorplanPose(Map<String, dynamic>? navResultData) {
  if (navResultData == null) return null;

  final dynamic pose = navResultData['floorplan_pose'];
  if (pose is! Map) return null;

  double? readNum(dynamic value) => value is num ? value.toDouble() : null;

  final double? x =
      readNum(pose['x']) ??
      readNum(pose['px']) ??
      readNum(pose['u']) ??
      readNum(pose['col']);
  final double? y =
      readNum(pose['y']) ??
      readNum(pose['py']) ??
      readNum(pose['v']) ??
      readNum(pose['row']);

  if (x != null && y != null) {
    return Offset(x, y);
  }
  return null;
}

/// Projects the current pose to the closest point on the path.
List<Offset> buildTrackedPath(List<Offset> fullPath, Offset? currentPose) {
  if (fullPath.length < 2 || currentPose == null)
    return List<Offset>.from(fullPath);

  double bestDistanceSq = double.infinity;
  Offset? bestProjection;
  int bestSegmentStart = 0;

  for (int i = 0; i < fullPath.length - 1; i++) {
    final Offset a = fullPath[i];
    final Offset b = fullPath[i + 1];
    final Offset ab = b - a;
    final double abLenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (abLenSq <= 1e-6) continue;

    final Offset ap = currentPose - a;
    final double t = ((ap.dx * ab.dx) + (ap.dy * ab.dy)) / abLenSq;
    final double clampedT = t.clamp(0.0, 1.0);
    final Offset projection = Offset(
      a.dx + ab.dx * clampedT,
      a.dy + ab.dy * clampedT,
    );

    final double dx = currentPose.dx - projection.dx;
    final double dy = currentPose.dy - projection.dy;
    final double distanceSq = dx * dx + dy * dy;

    if (distanceSq < bestDistanceSq) {
      bestDistanceSq = distanceSq;
      bestProjection = projection;
      bestSegmentStart = i;
    }
  }

  if (bestProjection == null) return List<Offset>.from(fullPath);

  return [bestProjection, ...fullPath.skip(bestSegmentStart + 1)];
}

/// Splits a global navigation path into segments grouped by floor.
Map<String, List<Offset>> splitPathByFloor(
  List<dynamic> pathKeys,
  List<dynamic> pathCoords,
) {
  final Map<String, List<Offset>> floorSegs = {};
  for (int i = 0; i < pathKeys.length; ++i) {
    final dynamic key = pathKeys[i];
    final dynamic coord = pathCoords[i];
    if (key is List && key.length >= 3) {
      final String floorKey = "${key[0]}|${key[1]}|${key[2]}";
      floorSegs.putIfAbsent(floorKey, () => []);
      floorSegs[floorKey]!.add(
        Offset((coord[0] as num).toDouble(), (coord[1] as num).toDouble()),
      );
    }
  }
  return floorSegs;
}
