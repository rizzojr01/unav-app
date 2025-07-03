import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

import '../api/api_service.dart';
import 'place_select_screen.dart';
import '../providers/settings_provider.dart';

/// StartupScreen
/// Main entry point for UNav.
/// Handles login, registration, persistent user profile, avatar selection/cropping/upload,
/// avatar downloading from server after login, and seamless auto-login experience.
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  // --- Form controllers ---
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _loginPwdController = TextEditingController();
  final TextEditingController _regEmailController = TextEditingController();
  final TextEditingController _regNicknameController = TextEditingController();
  final TextEditingController _regPwdController = TextEditingController();
  final TextEditingController _regPwd2Controller = TextEditingController();
  final TextEditingController _regCodeController = TextEditingController();

  // --- UI state ---
  String? _serverAddress, _errorMsg, _regPwdMismatchMsg, _regCodeMsg;
  bool _isLoading = false, _registerMode = false, _showFullLogin = false;
  bool _codeSent = false;
  int _codeTimeout = 0;
  Timer? _timer;
  bool _isRegFormValid = false, _isCodeFilled = false;

  // --- Cached profile and preferences ---
  String? _cachedEmail, _cachedNickname, _cachedAvatarUrl, _cachedUnit, _cachedLanguage;
  File? _cachedAvatarFile;
  Key _avatarKey = UniqueKey(); // Key to force avatar image refresh

  // --- Supported language list ---
  final List<Map<String, String>> _languages = [
    {'code': 'en', 'name': 'English'},
    {'code': 'zh', 'name': '中文'},
    {'code': 'th', 'name': 'ไทย'},
  ];

  @override
  void initState() {
    super.initState();
    _loadServerAddress();
    _loadUnitAndLanguageToProvider();
    _loadCachedProfileAndPrefs();
    _regPwdController.addListener(_validateRegisterForm);
    _regPwd2Controller.addListener(_validateRegisterForm);
    _regEmailController.addListener(_validateRegisterForm);
    _regNicknameController.addListener(_validateRegisterForm);
    _regCodeController.addListener(_validateRegisterForm);
    _tryAutoLogin();
  }

  /// Loads cached user info, preferences, and avatar from persistent storage.
  Future<void> _loadCachedProfileAndPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _cachedEmail = prefs.getString('saved_email');
      _cachedNickname = prefs.getString('saved_nickname');
      _cachedAvatarUrl = prefs.getString('saved_avatar_url');
      _cachedUnit = prefs.getString('saved_unit') ?? "feet";
      _cachedLanguage = prefs.getString('saved_language') ?? "en";
    });
    final provider = context.read<SettingsProvider>();
    provider.setAll(language: _cachedLanguage!, unit: _cachedUnit!);
    provider.setEmail(_cachedEmail ?? "");
    provider.setNickname(_cachedNickname ?? "");
    final localAvatarPath = prefs.getString('saved_avatar_local');
    if (localAvatarPath != null && File(localAvatarPath).existsSync()) {
      _cachedAvatarFile = File(localAvatarPath);
      await provider.saveAvatar(_cachedAvatarFile!);
      setState(() => _avatarKey = UniqueKey());
    } else if (_cachedAvatarUrl != null && _cachedAvatarUrl!.isNotEmpty) {
      await provider.saveAvatarUrl(_cachedAvatarUrl!);
    }
  }

  /// Loads unit and language to Provider from storage.
  Future<void> _loadUnitAndLanguageToProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final unit = prefs.getString('saved_unit') ?? "feet";
    final lang = prefs.getString('saved_language') ?? "en";
    final provider = context.read<SettingsProvider>();
    provider.setAll(language: lang, unit: unit);
  }

  /// Downloads avatar from server URL and saves locally.
  Future<void> _downloadAndSaveAvatar(String avatarUrl) async {
    try {
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(avatarUrl));
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(response);
        final appDocDir = await getApplicationDocumentsDirectory();
        final localPath = '${appDocDir.path}/avatar.jpg';
        final file = File(localPath);
        await file.writeAsBytes(bytes);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('saved_avatar_local', localPath);
        setState(() {
          _cachedAvatarFile = file;
          _avatarKey = UniqueKey();
        });
        final provider = context.read<SettingsProvider>();
        await provider.saveAvatar(file);
      }
    } catch (e) {}
  }

  /// Attempts auto-login with saved credentials, otherwise shows login UI.
  Future<void> _tryAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString('saved_email');
    final pwd = prefs.getString('saved_password');
    final nickname = prefs.getString('saved_nickname');
    final avatarUrl = prefs.getString('saved_avatar_url');
    final unit = prefs.getString('saved_unit') ?? "feet";
    final lang = prefs.getString('saved_language') ?? "en";
    final provider = context.read<SettingsProvider>();

    if (email != null && pwd != null) {
      final resp = await ApiService.login(email, pwd);
      if (!resp.containsKey('error')) {
        provider.setEmail(email);
        provider.setNickname(resp['nickname'] ?? nickname ?? "");
        String? newAvatarUrl = resp['avatar_url'];
        if (newAvatarUrl != null && newAvatarUrl.isNotEmpty) {
          String fullUrl = newAvatarUrl.startsWith('http')
              ? newAvatarUrl
              : 'http://unav.zapto.org:5001$newAvatarUrl';
          await _downloadAndSaveAvatar(fullUrl);
          await provider.saveAvatarUrl(fullUrl);
          await _saveProfileAndPrefs(
            email, pwd, provider.nickname, fullUrl, unit, lang,
            avatarLocalPath: _cachedAvatarFile?.path,
          );
        } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
          await provider.saveAvatarUrl(avatarUrl);
        }
        provider.setAll(language: lang, unit: unit);
        if (provider.setLoggedIn != null) await provider.setLoggedIn(true);
        setState(() {
          _showFullLogin = false;
          _errorMsg = null;
        });
        return;
      } else {
        await _clearCachedProfileAndPrefs();
        setState(() {
          _showFullLogin = true;
          _errorMsg = _backendErrorToText(resp['error']);
        });
      }
    } else {
      setState(() {
        _showFullLogin = true;
      });
    }
  }

  /// Saves user profile and preferences to persistent storage.
  Future<void> _saveProfileAndPrefs(
    String email,
    String password,
    String? nickname,
    String? avatarUrl,
    String unit,
    String language, {
    String? avatarLocalPath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_email', email);
    await prefs.setString('saved_password', password);
    if (nickname != null) await prefs.setString('saved_nickname', nickname);
    if (avatarUrl != null) await prefs.setString('saved_avatar_url', avatarUrl);
    await prefs.setString('saved_unit', unit);
    await prefs.setString('saved_language', language);
    if (avatarLocalPath != null) await prefs.setString('saved_avatar_local', avatarLocalPath);
    setState(() {
      _cachedEmail = email;
      _cachedNickname = nickname;
      _cachedAvatarUrl = avatarUrl;
      _cachedUnit = unit;
      _cachedLanguage = language;
    });
  }

  /// Clears all saved credentials, profile, and preferences.
  Future<void> _clearCachedProfileAndPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final localAvatarPath = prefs.getString('saved_avatar_local');
    if (localAvatarPath != null) {
      final file = File(localAvatarPath);
      if (await file.exists()) await file.delete();
      await prefs.remove('saved_avatar_local');
    }
    await prefs.remove('saved_email');
    await prefs.remove('saved_password');
    await prefs.remove('saved_nickname');
    await prefs.remove('saved_avatar_url');
    await prefs.remove('saved_unit');
    await prefs.remove('saved_language');
    setState(() {
      _cachedEmail = null;
      _cachedNickname = null;
      _cachedAvatarUrl = null;
      _cachedUnit = null;
      _cachedLanguage = null;
      _cachedAvatarFile = null;
      _avatarKey = UniqueKey();
    });
    await context.read<SettingsProvider>().clearProfile();
  }

  /// Handles login: checks input validity, only sends request if valid.
  Future<void> _handleLogin() async {
    String email = _emailController.text.trim();
    String pwd = _loginPwdController.text;

    // Validate email and password locally before request
    if (!email.contains('@') || email.isEmpty) {
      setState(() {
        _errorMsg = "Please enter a valid email address.";
      });
      return;
    }
    if (pwd.isEmpty) {
      setState(() {
        _errorMsg = "Password cannot be empty.";
      });
      return;
    }

    setState(() { _isLoading = true; _errorMsg = null; });
    await _saveServerAddress(_serverAddress ?? "http://unav.zapto.org:5001");
    final provider = context.read<SettingsProvider>();
    try {
      final resp = await ApiService.login(
        email,
        pwd,
      );
      if (resp.containsKey("error")) {
        setState(() {
          _errorMsg = _backendErrorToText(resp["error"]);
          _isLoading = false;
        });
        return;
      }
      provider.setEmail(email);
      provider.setNickname(resp["nickname"] ?? "");
      String? avatarUrl = resp['avatar_url'];
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        String fullUrl = avatarUrl.startsWith('http')
            ? avatarUrl
            : 'http://unav.zapto.org:5001$avatarUrl';
        await _downloadAndSaveAvatar(fullUrl);
        await provider.saveAvatarUrl(fullUrl);
        await _saveProfileAndPrefs(
          email,
          pwd,
          provider.nickname,
          fullUrl,
          provider.unit,
          provider.languageCode,
          avatarLocalPath: _cachedAvatarFile?.path,
        );
        setState(() => _avatarKey = UniqueKey());
      } else if (provider.avatarUrl != null) {
        await provider.saveAvatarUrl(provider.avatarUrl!);
      }
      await _onAuthSuccess(
        email,
        pwd,
        provider.nickname,
        provider.avatarUrl,
        avatarLocalPath: _cachedAvatarFile?.path,
      );
    } catch (e) {
      setState(() {
        _errorMsg = "Network or server error!";
        _isLoading = false;
      });
    }
  }

  /// Handles registration, then logs in and saves info on success.
  Future<void> _handleRegister() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
      _regPwdMismatchMsg = null;
      _regCodeMsg = null;
    });
    if (!_isRegFormValid || !_isCodeFilled) {
      setState(() {
        _errorMsg = "Please complete the form correctly.";
        _isLoading = false;
      });
      return;
    }
    await _saveServerAddress(_serverAddress ?? "http://unav.zapto.org:5001");
    final provider = context.read<SettingsProvider>();
    try {
      final resp = await ApiService.register(
        _regEmailController.text.trim(),
        _regNicknameController.text.trim(),
        _regPwdController.text,
        _regCodeController.text.trim(),
      );
      if (resp.containsKey("error")) {
        setState(() {
          if (resp["error"] == "invalid_or_expired_code") {
            _regCodeMsg = "Invalid or expired verification code.";
          } else if (resp["error"] == "user_exists") {
            _errorMsg = "User already exists. Please login.";
          } else {
            _errorMsg = _backendErrorToText(resp["error"]);
          }
          _isLoading = false;
        });
        return;
      }
      final loginResp = await ApiService.login(
        _regEmailController.text.trim(),
        _regPwdController.text,
      );
      if (loginResp.containsKey("error")) {
        setState(() {
          _errorMsg = _backendErrorToText(loginResp["error"]);
          _isLoading = false;
        });
        return;
      }
      provider.setEmail(_regEmailController.text.trim());
      provider.setNickname(_regNicknameController.text.trim());

      String? avatarUrl = loginResp['avatar_url'];
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        String fullUrl = avatarUrl.startsWith('http')
            ? avatarUrl
            : 'http://unav.zapto.org:5001$avatarUrl';
        await _downloadAndSaveAvatar(fullUrl);
        await provider.saveAvatarUrl(fullUrl);
        await _saveProfileAndPrefs(
          _regEmailController.text.trim(),
          _regPwdController.text,
          provider.nickname,
          fullUrl,
          provider.unit,
          provider.languageCode,
          avatarLocalPath: _cachedAvatarFile?.path,
        );
        setState(() => _avatarKey = UniqueKey());
      } else if (provider.avatarUrl != null) {
        await provider.saveAvatarUrl(provider.avatarUrl!);
      }
      await _onAuthSuccess(
        _regEmailController.text.trim(),
        _regPwdController.text,
        provider.nickname,
        provider.avatarUrl,
        avatarLocalPath: _cachedAvatarFile?.path,
      );
    } catch (e) {
      setState(() {
        _errorMsg = "Network or server error!";
        _isLoading = false;
      });
    }
  }

  /// Validates registration form and updates UI state.
  void _validateRegisterForm() {
    String email = _regEmailController.text.trim();
    String nickname = _regNicknameController.text.trim();
    String pwd1 = _regPwdController.text;
    String pwd2 = _regPwd2Controller.text;
    String code = _regCodeController.text.trim();
    bool isPwdMatch = pwd1.isNotEmpty && pwd2.isNotEmpty && pwd1 == pwd2;
    bool isEmail = email.contains('@');
    bool isNickname = nickname.isNotEmpty;
    bool isPwdValid = pwd1.length >= 6;
    bool isCode = code.isNotEmpty;
    setState(() {
      _isRegFormValid = isEmail && isNickname && isPwdValid && isPwdMatch;
      _isCodeFilled = isCode;
      _regPwdMismatchMsg = (!isPwdMatch && pwd2.isNotEmpty) ? "Passwords do not match!" : null;
    });
  }

  /// Converts backend error codes to human-readable messages.
  String _backendErrorToText(String error) {
    switch (error) {
      case "user_exists": return "User already exists.";
      case "invalid_or_expired_code": return "Invalid or expired verification code.";
      case "empty_field": return "Please complete all fields.";
      case "incorrect_credentials": return "Incorrect email or password.";
      case "invalid_email": return "Invalid email address.";
      default: return error;
    }
  }

  /// Unit selector row. Updates provider and persists user's unit preference.
  Widget _unitSelector() {
    final provider = context.watch<SettingsProvider>();
    return Row(
      children: [
        const Text("Unit:", style: TextStyle(fontSize: 18)),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () async {
            provider.setUnit('feet');
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('saved_unit', 'feet');
          },
          style: OutlinedButton.styleFrom(
            backgroundColor: provider.unit == "feet" ? Colors.blueAccent : Colors.transparent,
          ),
          child: Text("Feet", style: TextStyle(color: provider.unit == "feet" ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () async {
            provider.setUnit('meter');
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('saved_unit', 'meter');
          },
          style: OutlinedButton.styleFrom(
            backgroundColor: provider.unit == "meter" ? Colors.blueAccent : Colors.transparent,
          ),
          child: Text("Meter", style: TextStyle(color: provider.unit == "meter" ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  /// Language selector dropdown. Updates provider and persists user's language choice.
  Widget _languageSelector() {
    final provider = context.watch<SettingsProvider>();
    return Row(
      children: [
        const Text("Language:", style: TextStyle(fontSize: 18)),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: provider.languageCode,
          items: _languages.map((lang) {
            return DropdownMenuItem(
              value: lang['code'],
              child: Text(lang['name'] ?? ""),
            );
          }).toList(),
          onChanged: (String? value) async {
            if (value != null) {
              provider.setLanguage(value);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('saved_language', value);
            }
          },
        ),
      ],
    );
  }

  /// Handles logout. Clears all credentials and resets UI to login/register state.
  Future<void> _logout() async {
    await ApiService.logout();
    await _clearCachedProfileAndPrefs();
    setState(() {
      _errorMsg = null;
      _showFullLogin = true;
    });
  }

  /// Handles avatar selection, cropping, resizing, upload, and local storage.
  Future<void> _pickAvatar() async {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90);
                if (picked != null) await _cropAndSetAvatar(File(picked.path));
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
                if (picked != null) await _cropAndSetAvatar(File(picked.path));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Crops image, saves locally, uploads to server, updates provider/cache, and forces avatar UI reload.
  Future<void> _cropAndSetAvatar(File imageFile) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      maxWidth: 256,
      maxHeight: 256,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 90,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Avatar',
          lockAspectRatio: true,
          initAspectRatio: CropAspectRatioPreset.square,
        ),
        IOSUiSettings(
          title: 'Crop Avatar',
          aspectRatioLockEnabled: true,
        ),
      ],
    );
    if (cropped == null) return;

    final File croppedFile = File(cropped.path);
    final appDocDir = await getApplicationDocumentsDirectory();
    final localAvatarPath = '${appDocDir.path}/avatar.jpg';
    final localAvatarFile = await croppedFile.copy(localAvatarPath);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_avatar_local', localAvatarPath);
    final provider = context.read<SettingsProvider>();
    await provider.saveAvatar(localAvatarFile);

    setState(() {
      _cachedAvatarFile = localAvatarFile;
      _avatarKey = UniqueKey(); // Force UI reload
    });

    // Upload to server
    final email = provider.email;
    if (email.isNotEmpty) {
      final bytes = await localAvatarFile.readAsBytes();
      final uploadResp = await ApiService.uploadAvatar(bytes, "avatar.jpg", email);
      final url = uploadResp['url'];
      if (url != null && (url as String).isNotEmpty) {
        String avatarUrl = url as String;
        await provider.saveAvatarUrl(avatarUrl);
        String fullUrl = avatarUrl.startsWith('http')
            ? avatarUrl
            : 'http://unav.zapto.org:5001$avatarUrl';
        fullUrl += '?t=${DateTime.now().millisecondsSinceEpoch}';
        await _downloadAndSaveAvatar(fullUrl);
        await _onAuthSuccess(email, _loginPwdController.text, provider.nickname, avatarUrl, avatarLocalPath: localAvatarPath);
        setState(() => _avatarKey = UniqueKey()); // Ensure UI always refreshes
      }
    }
  }

  /// Unified handler to save all info after login/registration/avatar update.
  Future<void> _onAuthSuccess(
    String email,
    String password,
    String? nickname,
    String? avatarUrl, {
    String? avatarLocalPath,
  }) async {
    final provider = context.read<SettingsProvider>();
    await _saveProfileAndPrefs(
      email, password, nickname, avatarUrl, provider.unit, provider.languageCode,
      avatarLocalPath: avatarLocalPath,
    );
    await ApiService.selectUnit(provider.unit);
    await ApiService.selectLanguage(provider.languageCode);
    if (provider.setLoggedIn != null) await provider.setLoggedIn(true);
    if (context.mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PlaceSelectScreen()));
    }
  }

  /// Loads server address from storage.
  Future<void> _loadServerAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString("server_address") ?? "http://unav.zapto.org:5001";
    ApiService.setServer(saved);
    setState(() => _serverAddress = saved);
  }

  /// Saves server address to storage.
  Future<void> _saveServerAddress(String addr) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_address", addr);
    ApiService.setServer(addr);
    setState(() => _serverAddress = addr);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _loginPwdController.dispose();
    _regEmailController.dispose();
    _regNicknameController.dispose();
    _regPwdController.dispose();
    _regPwd2Controller.dispose();
    _regCodeController.dispose();
    super.dispose();
  }

  /// Main build method. Shows profile card if logged in, else shows login/register forms.
  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final avatarFile = settingsProvider.avatarFile ?? _cachedAvatarFile;
    final avatarUrl = (settingsProvider.avatarUrl != null && settingsProvider.avatarUrl!.isNotEmpty)
        ? settingsProvider.avatarUrl!
        : (_cachedAvatarUrl ?? "");

    // 1. If user is logged in and not in register/forced-login mode, show profile card
    if ((settingsProvider.isLoggedIn ?? false) && !_registerMode && !_showFullLogin) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('UNav'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Logout',
              onPressed: _logout,
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _pickAvatar,
                child: CircleAvatar(
                  key: _avatarKey,
                  radius: 48,
                  backgroundColor: Colors.grey[350],
                  backgroundImage: avatarFile != null
                      ? FileImage(avatarFile)
                      : (avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) as ImageProvider : null),
                  child: (avatarFile == null && avatarUrl.isEmpty)
                      ? const Icon(Icons.person, color: Colors.white, size: 48)
                      : null,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                settingsProvider.nickname.isNotEmpty
                    ? settingsProvider.nickname
                    : settingsProvider.email.isNotEmpty
                        ? settingsProvider.email
                        : (_cachedNickname ?? _cachedEmail ?? ""),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isLoading ? null : _enterAppWithAutoLogin,
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                child: _isLoading ? const CircularProgressIndicator() : const Text("Enter App"),
              ),
              if (_errorMsg != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(_errorMsg!, style: const TextStyle(color: Colors.red, fontSize: 16)),
                ),
            ],
          ),
        ),
      );
    }

    // 2. Otherwise show login or register form
    return Scaffold(
      appBar: AppBar(
        title: const Text('UNav'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: GestureDetector(
              onTap: _pickAvatar,
              child: CircleAvatar(
                key: _avatarKey,
                radius: 22,
                backgroundColor: Colors.grey[350],
                backgroundImage: avatarFile != null
                    ? FileImage(avatarFile)
                    : (avatarUrl.isNotEmpty
                        ? NetworkImage(avatarUrl) as ImageProvider
                        : null),
                child: (avatarFile == null && avatarUrl.isEmpty)
                    ? const Icon(Icons.person, color: Colors.white, size: 32)
                    : null,
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: _registerMode ? _buildRegisterForm() : _buildLoginForm(),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_registerMode)
                TextButton(
                  onPressed: () => setState(() { _registerMode = true; }),
                  child: const Text("No account? Register", style: TextStyle(fontSize: 16)),
                ),
              if (_registerMode)
                TextButton(
                  onPressed: () => setState(() { _registerMode = false; }),
                  child: const Text("Already registered? Login", style: TextStyle(fontSize: 16)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Login form (email, password)
  Widget _buildLoginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text("Welcome to UNav", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 32),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: "Email",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _loginPwdController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Password",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        const SizedBox(height: 20),
        _unitSelector(),
        const SizedBox(height: 12),
        _languageSelector(),
        const SizedBox(height: 12),
        if (_errorMsg != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(_errorMsg!, style: const TextStyle(color: Colors.red, fontSize: 16)),
          ),
        ElevatedButton(
          onPressed: _isLoading ? null : _handleLogin,
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: _isLoading ? const CircularProgressIndicator() : const Text("Login"),
        ),
      ],
    );
  }

  /// Registration form (email, nickname, password, confirm, code)
  Widget _buildRegisterForm() {
    final sendCodeEnabled = _isRegFormValid && !_codeSent && _codeTimeout == 0;
    final registerEnabled = _isRegFormValid && _isCodeFilled && !_isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text("Register for UNav", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 32),
        TextField(
          controller: _regEmailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: "Email",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _regNicknameController,
          decoration: const InputDecoration(
            labelText: "Nickname",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _regPwdController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Password",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _regPwd2Controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Confirm Password",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        if (_regPwdMismatchMsg != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Text(_regPwdMismatchMsg!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _regCodeController,
                decoration: const InputDecoration(
                  labelText: "Verification Code",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.verified_user),
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: sendCodeEnabled ? _sendVerificationCode : null,
              child: Text(
                _codeTimeout > 0
                    ? "Resend (${_codeTimeout}s)"
                    : (_codeSent ? "Resend" : "Send Code"),
              ),
            ),
          ],
        ),
        if (_regCodeMsg != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Text(_regCodeMsg!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 20),
        _unitSelector(),
        const SizedBox(height: 12),
        _languageSelector(),
        const SizedBox(height: 12),
        if (_errorMsg != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(_errorMsg!, style: const TextStyle(color: Colors.red, fontSize: 16)),
          ),
        ElevatedButton(
          onPressed: registerEnabled ? _handleRegister : null,
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: _isLoading ? const CircularProgressIndicator() : const Text("Register"),
        ),
      ],
    );
  }

  /// Sends email verification code for registration.
  Future<void> _sendVerificationCode() async {
    final email = _regEmailController.text.trim();
    if (!email.contains('@')) {
      setState(() => _regCodeMsg = "Please enter a valid email address.");
      return;
    }
    setState(() {
      _regCodeMsg = null;
      _codeSent = false;
      _codeTimeout = 0;
    });
    try {
      final resp = await ApiService.sendVerificationCode(email);
      if (resp.containsKey("msg")) {
        setState(() {
          _codeSent = true;
          _codeTimeout = 60;
          _regCodeMsg = "Verification code sent to $email.";
        });
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() {
            _codeTimeout -= 1;
            if (_codeTimeout <= 0) {
              timer.cancel();
            }
          });
        });
      } else if (resp.containsKey("error")) {
        setState(() => _regCodeMsg = _backendErrorToText(resp["error"]));
      } else {
        setState(() => _regCodeMsg = "Failed to send verification code.");
      }
    } catch (e) {
      setState(() => _regCodeMsg = "Network or server error.");
    }
  }

  /// When user clicks Enter App (after auto-login profile card), verifies credentials and enters the app.
  Future<void> _enterAppWithAutoLogin() async {
    final provider = context.read<SettingsProvider>();
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString('saved_email');
    final pwd = prefs.getString('saved_password');
    final nickname = prefs.getString('saved_nickname');
    final avatarUrl = prefs.getString('saved_avatar_url');
    final localAvatarPath = prefs.getString('saved_avatar_local');
    if (email == null || pwd == null) {
      setState(() {
        _showFullLogin = true;
        _errorMsg = null;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    final resp = await ApiService.login(email, pwd);
    if (resp.containsKey('error')) {
      await _clearCachedProfileAndPrefs();
      setState(() {
        _isLoading = false;
        _showFullLogin = true;
        _errorMsg = _backendErrorToText(resp['error']);
      });
      return;
    }
    provider.setEmail(email);
    provider.setNickname(resp['nickname'] ?? nickname ?? "");
    String? serverAvatarUrl = resp['avatar_url'];
    if (serverAvatarUrl != null && serverAvatarUrl.isNotEmpty) {
      String fullUrl = serverAvatarUrl.startsWith('http')
          ? serverAvatarUrl
          : 'http://unav.zapto.org:5001$serverAvatarUrl';
      await _downloadAndSaveAvatar(fullUrl);
      await provider.saveAvatarUrl(fullUrl);
      setState(() => _avatarKey = UniqueKey());
    } else if (localAvatarPath != null && File(localAvatarPath).existsSync()) {
      await provider.saveAvatar(File(localAvatarPath));
    } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
      await provider.saveAvatarUrl(avatarUrl);
    }
    await _onAuthSuccess(email, pwd, provider.nickname, provider.avatarUrl, avatarLocalPath: localAvatarPath);
  }
}
