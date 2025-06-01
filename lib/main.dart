import 'package:flutter/material.dart';
import 'screens/startup_screen.dart';

void main() {
  runApp(const UNavApp());
}

class UNavApp extends StatelessWidget {
  const UNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UNav Navigation',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ),
      home: const StartupScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
