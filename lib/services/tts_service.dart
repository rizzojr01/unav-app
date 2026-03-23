// lib/services/tts_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  static final FlutterTts _tts = FlutterTts();
  static String _currentLang = 'en-US';
  static bool _iosAudioConfigured = false;

  static Future<void> _configurePlatformAudioSession() async {
    if (!Platform.isIOS || _iosAudioConfigured) return;

    await _tts.setSharedInstance(true);
    await _tts.autoStopSharedSession(false);
    await _tts.setIosAudioCategory(
      IosTextToSpeechAudioCategory.playback,
      <IosTextToSpeechAudioCategoryOptions>[
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        IosTextToSpeechAudioCategoryOptions.allowBluetooth,
        IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
      ],
      IosTextToSpeechAudioMode.voicePrompt,
    );
    _iosAudioConfigured = true;
  }

  static Future<void> setLanguage(String langCode) async {
    await _configurePlatformAudioSession();
    try {
      await _tts.setEngine('com.google.android.tts');
    } catch (e) {
      print('Warning: Failed to set Google TTS engine -> $e');
    }

    final normalized = langCode.trim();
    String locale;
    if (normalized.isEmpty) {
      locale = 'en-US';
    } else if (normalized.contains('-')) {
      locale = normalized;
    } else {
      switch (normalized) {
        case 'zh':
          locale = 'zh-CN';
          break;
        case 'th':
          locale = 'th-TH';
          break;
        case 'es':
          locale = 'es-ES';
          break;
        case 'fr':
          locale = 'fr-FR';
          break;
        case 'de':
          locale = 'de-DE';
          break;
        case 'ja':
          locale = 'ja-JP';
          break;
        case 'ko':
          locale = 'ko-KR';
          break;
        default:
          locale = 'en-US';
      }
    }
    _currentLang = locale;

    int result = await _tts.setLanguage(locale);
    print('TTS setLanguage($locale) -> $result');
  }

  /// Speaks a single sentence, stops any existing speech first.
  static Future<void> speak(String text) async {
    final cleaned = _sanitize(text);
    if (cleaned.isEmpty) return;

    await _configurePlatformAudioSession();
    await _tts.stop();
    await _tts.setLanguage(_currentLang);
    await _tts.speak(cleaned);
  }

  static Future<void> speakAndWait(String text) async {
    await _speakAndWait(text);
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
    await _configurePlatformAudioSession();
    await _tts.stop();
    await _tts.setLanguage(_currentLang);
    await _tts.speak(cleaned);

    void finish() {
      if (!completer.isCompleted) {
        completer.complete();
      }
      _tts.setCompletionHandler(() {});
      _tts.setCancelHandler(() {});
    }
    _tts.setCompletionHandler(finish);
    _tts.setCancelHandler(finish);

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
