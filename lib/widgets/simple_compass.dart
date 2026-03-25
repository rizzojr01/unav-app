import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../screens/debug_image_screen.dart';

/// A minimalist compass widget that displays orientation in Degrees.
class SimpleCompass extends StatelessWidget {
  final double heading; // Raw value in degrees received from the backend
  final double size;

  const SimpleCompass({super.key, required this.heading, this.size = 72});

  @override
  Widget build(BuildContext context) {
    const primaryColor = Colors.green;

    // Use the raw heading as Degrees
    final double displayedDegrees = heading;

    return GestureDetector(
      onDoubleTap: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const DebugImageScreen()));
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Digits Display
          Text(
            '${displayedDegrees.toStringAsFixed(1)}°',
            style: const TextStyle(
              color: primaryColor,
              fontSize: 16,
              fontWeight: FontWeight.w400,
              fontFamily: 'Courier',
            ),
          ),
          const SizedBox(height: 8),

          // The Compass Dial
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
                      color: primaryColor.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                ),

                // The Arrow (Rotating based on the degrees, with 0 pointing East)
                Transform.rotate(
                  angle: (displayedDegrees * math.pi / 180) + (math.pi / 2),
                  child: CustomPaint(
                    size: Size(size * 0.7, size * 0.7),
                    painter: _CompassArrowPainter(color: primaryColor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompassArrowPainter extends CustomPainter {
  final Color color;
  _CompassArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Arrow Path (Sharp edges, minimalist)
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final path = Path();
    path.moveTo(size.width * 0.5, size.height * 0.1);
    path.lineTo(size.width * 0.3, size.height * 0.8);
    path.lineTo(size.width * 0.5, size.height * 0.7);
    path.lineTo(size.width * 0.7, size.height * 0.8);
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, strokePaint);

    // Small center dot
    final corePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, size.width * 0.05, corePaint);

    // Faint outer ring
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
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
