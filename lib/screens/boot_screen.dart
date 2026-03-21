import 'package:flutter/material.dart';

import 'startup_screen.dart';

class BootScreen extends StatefulWidget {
  const BootScreen({super.key});

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) => const StartupScreen(),
          transitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF08131F),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.navigation_rounded,
              size: 72,
              color: Color(0xFF9FE7FF),
            ),
            SizedBox(height: 20),
            Text(
              'UNav',
              style: TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 10),
            Text(
              'Preparing navigation services...',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
            SizedBox(height: 24),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Color(0xFF9FE7FF),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
