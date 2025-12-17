// lib/services/tts_service.dart
import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  static final FlutterTts _tts = FlutterTts();
  static String _currentLang = 'en-US';

  static Future<void> setLanguage(String langCode) async {
    try {
      await _tts.setEngine('com.google.android.tts');
    } catch (e) {
      print('Warning: Failed to set Google TTS engine -> $e');
    }

    String locale = 'en-US';
    if (langCode == 'zh') {
      locale = 'zh-CN';
    } else if (langCode == 'th') {
      locale = 'th-TH';
    }
    _currentLang = locale;

    int result = await _tts.setLanguage(locale);
    print('TTS setLanguage($locale) -> $result');
  }

  /// Speaks a single sentence, stops any existing speech first.
  static Future<void> speak(String text) async {
    final cleaned = _sanitize(text);
    if (cleaned.isEmpty) return;

    await _tts.stop();
    await _tts.setLanguage(_currentLang);
    await _tts.speak(cleaned);
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
    final cleaned = _sanitize(text);
    if (cleaned.isEmpty) return;

    final completer = Completer<void>();
    await _tts.stop();
    await _tts.setLanguage(_currentLang);
    await _tts.speak(cleaned);

    void handler() {
      completer.complete();
      _tts.setCompletionHandler(() {}); // remove handler after once
    }
    _tts.setCompletionHandler(handler);

    return completer.future;
  }

  /// --- Text filter ---
  static String _sanitize(String input) {
    var t = input;

    // 去掉控制字符
    t = t.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ');

    // 先把下划线替换成空格
    t = t.replaceAll('_', ' ');

    // 压缩多余空白
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    // URL、文件路径、邮箱替换为口语化词
    t = t.replaceAll(RegExp(r'https?://\S+'), 'a link');
    t = t.replaceAll(RegExp(r'\b[\w\-.]+@[\w\-.]+\b'), 'an email');
    t = t.replaceAll(RegExp(r'([A-Za-z]:)?[\\/][^\s]+'), 'a file path');

    // 过滤 emoji（避免拼音拼读）
    t = t.replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true), '');

    return t;
  }
}
