// lib/services/tts_service.dart
import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  static final FlutterTts _tts = FlutterTts();
  static String _currentLang = 'en-US';

  static Future<void> setLanguage(String langCode) async {
    // Map 'en', 'zh', 'th' to system locale string
    String locale = 'en-US';
    if (langCode == 'zh') locale = 'zh-CN';
    else if (langCode == 'th') locale = 'th-TH';
    _currentLang = locale;
    await _tts.setLanguage(locale);
  }

  /// Speaks a single sentence, stops any existing speech first.
  static Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.setLanguage(_currentLang); // ensure correct language
    await _tts.speak(text);
  }

  /// Stop any ongoing speech.
  static Future<void> stop() async {
    await _tts.stop();
  }

  /// Speak a list of sentences sequentially, waiting for each to finish.
  static Future<void> speakSequentially(List<String> sentences) async {
    for (final s in sentences) {
      await _speakAndWait(s);
    }
  }

  /// Helper: Speak a sentence and wait until it's finished before continuing.
  static Future<void> _speakAndWait(String text) async {
    final completer = Completer<void>();
    await _tts.stop();
    await _tts.setLanguage(_currentLang);
    await _tts.speak(text);

    // 注册无参数的回调
    void handler() {
      completer.complete();
      _tts.setCompletionHandler(() {}); // Remove the handler after called once
    }
    _tts.setCompletionHandler(handler);

    return completer.future;
  }
}
