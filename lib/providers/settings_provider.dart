import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SettingsProvider
/// ----------------
/// Centralized state manager for all user and application-wide settings.
/// Provides accessors and persistent setters for:
/// - App language (code)
/// - Navigation unit (feet/meter)
/// - Turn mode (default/deg15)
/// - User profile: email, nickname, avatar (local file and server URL)
/// - Login state
/// All mutations are reflected both in memory and in SharedPreferences,
/// supporting reliable auto-login and profile restoration across sessions.
class SettingsProvider extends ChangeNotifier {
  // --- User settings ---
  String _languageCode = 'en'; // App language code: 'en', 'zh', 'th'
  String _unit = 'feet'; // Navigation unit: 'feet' or 'meter'
  String _turnMode = 'default'; // Turn mode: 'default' or 'deg15'
  bool _announceCurrentLocation = false;

  String? _email; // User email (login identifier)
  String? _nickname; // User nickname/display name
  File? _avatarFile; // Local avatar file (cropped and stored on device)
  String? _avatarUrl; // Remote avatar URL (from server after upload)
  bool _isLoggedIn = false; // Login status flag

  // --- Getters (read-only to outside) ---
  String get languageCode => _languageCode;
  String get unit => _unit;
  String get turnMode => _turnMode;
  bool get announceCurrentLocation => _announceCurrentLocation;

  String get email => _email ?? '';
  String get nickname => _nickname ?? '';
  File? get avatarFile => _avatarFile;
  String? get avatarUrl => _avatarUrl;
  bool get isLoggedIn => _isLoggedIn;

  // --- Language selection (persistent) ---
  /// Sets application language, persists to storage, and notifies listeners.
  Future<void> setLanguage(String code) async {
    if (code != _languageCode) {
      _languageCode = code;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_language', code);
      notifyListeners();
    }
  }

  // --- 播报当前位置设置 (persistent) ---
  /// 设置是否播报当前位置，持久化到存储，并通知监听者
  Future<void> setAnnounceCurrentLocation(bool announce) async {
    if (announce != _announceCurrentLocation) {
      _announceCurrentLocation = announce;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('saved_announce_location', announce);
      notifyListeners();
    }
  }

  // --- Unit selection (persistent) ---
  /// Sets navigation distance unit, persists to storage, and notifies listeners.
  Future<void> setUnit(String unit) async {
    if (unit != _unit) {
      _unit = unit;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_unit', unit);
      notifyListeners();
    }
  }

  // --- Turn mode selection (persistent) ---
  /// Sets turn mode ('default' | 'deg15'), persists to storage, and notifies listeners.
  Future<void> setTurnMode(String mode) async {
    if (mode != _turnMode) {
      _turnMode = mode;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_turn_mode', mode);
      notifyListeners();
    }
  }

  /// Sets language, unit, and optionally turn mode, persists any changed values, then notifies.
  Future<void> setAll({
    required String language,
    required String unit,
    String? turnMode,
    bool? announceCurrentLocation,
  }) async {
    bool changed = false;
    final prefs = await SharedPreferences.getInstance();

    if (language != _languageCode) {
      _languageCode = language;
      await prefs.setString('saved_language', language);
      changed = true;
    }
    if (unit != _unit) {
      _unit = unit;
      await prefs.setString('saved_unit', unit);
      changed = true;
    }
    if (turnMode != null && turnMode != _turnMode) {
      _turnMode = turnMode;
      await prefs.setString('saved_turn_mode', turnMode);
      changed = true;
    }
    if (announceCurrentLocation != null &&
        announceCurrentLocation != _announceCurrentLocation) {
      _announceCurrentLocation = announceCurrentLocation;
      await prefs.setBool('saved_announce_location', announceCurrentLocation);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // --- User profile: email and nickname (in-memory only, but can be loaded/persisted) ---
  /// Sets user email and notifies listeners.
  void setEmail(String? email) {
    _email = email;
    notifyListeners();
  }

  /// Sets user nickname and notifies listeners.
  void setNickname(String? nickname) {
    _nickname = nickname;
    notifyListeners();
  }

  // --- Login state (persistent) ---
  /// Sets login state, persists to storage, and notifies listeners.
  Future<void> setLoggedIn(bool loggedIn) async {
    _isLoggedIn = loggedIn;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_logged_in', loggedIn);
    notifyListeners();
  }

  // --- Avatar (local file and server URL) ---
  /// Loads avatar file and remote URL from persistent storage.
  /// If a valid local avatar file exists, prefers that for display.
  Future<void> loadAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('avatar_path');
    final url = prefs.getString('avatar_url');
    if (path != null && File(path).existsSync()) {
      _avatarFile = File(path);
    } else {
      _avatarFile = null;
    }
    _avatarUrl = url;
    notifyListeners();
  }

  /// Saves avatar file (must be local/cropped), and optionally avatar URL if provided.
  /// Updates both memory and persistent storage, notifies listeners.
  Future<void> saveAvatar(File file, {String? url}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('avatar_path', file.path);
    _avatarFile = file;
    if (url != null) {
      _avatarUrl = url;
      await prefs.setString('avatar_url', url);
    }
    notifyListeners();
  }

  /// Saves only the avatar URL to memory and persistent storage.
  Future<void> saveAvatarUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _avatarUrl = url;
    await prefs.setString('avatar_url', url);
    notifyListeners();
  }

  // --- User profile (persistent load/save/clear) ---
  /// Loads all user profile info and settings from persistent storage.
  /// Should be called at app launch to restore state.
  Future<void> loadUserProfile() async {
    final prefs = await SharedPreferences.getInstance();
    _email = prefs.getString('user_email');
    _nickname = prefs.getString('user_nickname');
    _isLoggedIn = prefs.getBool('is_logged_in') ?? false;

    _languageCode = prefs.getString('saved_language') ?? 'en';
    _unit = prefs.getString('saved_unit') ?? 'feet';
    _turnMode = prefs.getString('saved_turn_mode') ?? 'default';
    _announceCurrentLocation =
        prefs.getBool('saved_announce_location') ?? false;

    await loadAvatar();
    _useDebugImage = prefs.getBool('use_debug_image') ?? false;
    _debugAssetPath = prefs.getString('debug_asset_path');
    notifyListeners();
  }

  // --- Debug Image (persistent) ---
  bool _useDebugImage = false;
  String? _debugAssetPath;

  bool get useDebugImage => _useDebugImage;
  String? get debugAssetPath => _debugAssetPath;

  Future<void> setDebugImageEnabled(bool enabled) async {
    if (_useDebugImage != enabled) {
      _useDebugImage = enabled;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('use_debug_image', enabled);
      notifyListeners();
    }
  }

  Future<void> setDebugAssetPath(String? path) async {
    if (_debugAssetPath != path) {
      _debugAssetPath = path;
      final prefs = await SharedPreferences.getInstance();
      if (path != null) {
        await prefs.setString('debug_asset_path', path);
      } else {
        await prefs.remove('debug_asset_path');
      }
      notifyListeners();
    }
  }

  /// Saves the user profile (email, nickname, avatarUrl) to persistent storage.
  /// Optionally updates login state.
  Future<void> setUserProfile({
    required String email,
    required String nickname,
    String? avatarUrl,
    bool loggedIn = true,
  }) async {
    _email = email;
    _nickname = nickname;
    _isLoggedIn = loggedIn;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_email', email);
    await prefs.setString('user_nickname', nickname);
    await prefs.setBool('is_logged_in', loggedIn);
    if (avatarUrl != null) {
      _avatarUrl = avatarUrl;
      await prefs.setString('avatar_url', avatarUrl);
    }
    notifyListeners();
  }

  // --- Avatar clearing ---
  /// Removes avatar file and URL from provider and persistent storage.
  Future<void> clearAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('avatar_path');
    await prefs.remove('avatar_url');
    _avatarFile = null;
    _avatarUrl = null;
    notifyListeners();
  }

  // --- Full profile clearing ---
  /// Removes all user profile info and preferences from provider and persistent storage (logout).
  Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_email');
    await prefs.remove('user_nickname');
    await prefs.remove('is_logged_in');
    await prefs.remove('saved_unit');
    await prefs.remove('saved_language');
    await prefs.remove('saved_turn_mode');
    await prefs.remove('saved_announce_location');
    await prefs.remove('use_debug_image');
    await prefs.remove('debug_asset_path');
    await clearAvatar();

    _email = null;
    _nickname = null;
    _isLoggedIn = false;

    _languageCode = 'en';
    _unit = 'feet';
    _turnMode = 'default';
    _announceCurrentLocation = false;
    _useDebugImage = false;
    _debugAssetPath = null;

    notifyListeners();
  }
}
