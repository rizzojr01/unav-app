import 'package:flutter/material.dart';

/// SettingsProvider manages global app settings such as language and unit.
/// Use with Provider for real-time UI updates when the user changes language or unit.
///
/// Example usage:
///   final lang = context.watch<SettingsProvider>().languageCode;
///   Provider.of<SettingsProvider>(context, listen: false).setLanguage('zh');
class SettingsProvider extends ChangeNotifier {
  String _languageCode = 'en'; // Supported: 'en', 'zh', 'th'
  String _unit = 'feet';       // Supported: 'feet', 'meter'

  /// Returns the currently selected language code.
  String get languageCode => _languageCode;

  /// Returns the currently selected unit for navigation.
  String get unit => _unit;

  /// Sets the app language and notifies listeners if changed.
  void setLanguage(String code) {
    if (code != _languageCode) {
      _languageCode = code;
      notifyListeners();
    }
  }

  /// Sets the navigation unit and notifies listeners if changed.
  void setUnit(String u) {
    if (u != _unit) {
      _unit = u;
      notifyListeners();
    }
  }

  /// Optionally sets both language and unit at once, notifying only if changed.
  void setAll({required String language, required String unit}) {
    bool changed = false;
    if (language != _languageCode) {
      _languageCode = language;
      changed = true;
    }
    if (unit != _unit) {
      _unit = unit;
      changed = true;
    }
    if (changed) notifyListeners();
  }
}
