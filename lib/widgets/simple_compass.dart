import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A premium compass widget that visualizes the current heading orientation.
/// Includes degree display and a stylized arrow with compass markings.
class SimpleCompass extends StatelessWidget {
  final double heading; // in degrees
  final double size;

  const SimpleCompass({super.key, required this.heading, this.size = 72});

  @override
  Widget build(BuildContext context) {
    const primaryColor = Colors.green;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Real-time degree display
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: primaryColor.withOpacity(0.5)),
          ),
          child: Text(
            '${heading.toStringAsFixed(1)}°',
            style: const TextStyle(
              color: primaryColor,
              fontSize: 16,
              fontWeight: FontWeight.w400,
              fontFamily: 'Courier',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.transparent,
            border: Border.all(
              color: primaryColor.withOpacity(0.8),
              width: 1.5,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Decorative Inner Ring
              Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: primaryColor.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
              ),

              // The Arrow (Rotating)
              Transform.rotate(
                angle: heading * math.pi / 180,
                child: CustomPaint(
                  size: Size(size * 0.7, size * 0.7),
                  painter: _CompassArrowPainter(color: primaryColor),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompassArrowPainter extends CustomPainter {
  final Color color;
  _CompassArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Redesigned Arrow (Green with white outline)
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final path = Path();
    // Generalized coordinates following M50 15 L35 75 L50 65 L65 75 Z
    path.moveTo(size.width * 0.5, size.height * 0.1);
    path.lineTo(size.width * 0.3, size.height * 0.8);
    path.lineTo(size.width * 0.5, size.height * 0.7);
    path.lineTo(size.width * 0.7, size.height * 0.8);
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, strokePaint);

    // Small center dot (Matching primary color)
    final corePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, size.width * 0.05, corePaint);

    // Outer faint ring for accent
    canvas.drawCircle(
      center,
      size.width * 0.45,
      Paint()
        ..color = Colors.white.withOpacity(0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
