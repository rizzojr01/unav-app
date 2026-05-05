// lib/screens/startup_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_service.dart';
import '../providers/settings_provider.dart';
import '../services/server_address_service.dart';
import '../services/trial_recorder.dart';
import '../widgets/server_selector.dart';
import 'navigation_mode_screen.dart';

/// StartupScreen
/// - Login / Register
/// - Auto login & local cache (email/nickname/avatar/unit/language/turn mode)
/// - Avatar pick/crop/upload
/// - Server selector (school key + editable URL)
/// - Relative URLs resolved by ServerAddressService.resolve
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  // -------------------- Controllers --------------------
  final _emailCtl = TextEditingController();
  final _pwdLoginCtl = TextEditingController();

  final _regEmailCtl = TextEditingController();
  final _regNicknameCtl = TextEditingController();
  final _regPwdCtl = TextEditingController();
  final _regPwd2Ctl = TextEditingController();
  final _regCodeCtl = TextEditingController();

  // -------------------- UI State --------------------
  bool _isLoading = false;
  bool _registerMode = false;
  bool _showFullLogin = false;
  String? _errorMsg;

  // Register form state
  bool _isRegFormValid = false;
  bool _isCodeFilled = false;
  String? _regPwdMismatchMsg;
  String? _regCodeMsg;
  bool _codeSent = false;
  int _codeTimeout = 0;
  Timer? _timer;

  // -------------------- Cached Profile --------------------
  String? _cachedEmail, _cachedNickname, _cachedAvatarUrl, _cachedUnit, _cachedLanguage;
  File? _cachedAvatarFile;
  Key _avatarKey = UniqueKey();

  // -------------------- Languages --------------------
  final List<Map<String, String>> _languages = const [
    {'code': 'en', 'name': 'English'},
    {'code': 'zh', 'name': '中文'},
    {'code': 'th', 'name': 'ไทย'},
  ];

  // -------------------- Turn Modes --------------------
  // 'default' -> classic clock/qual style
  // 'deg15'   -> left/right + degrees (15° quantization); U-turn still says "Make a U-turn"
  final List<Map<String, String>> _turnModes = const [
    {'code': 'default', 'name': 'Default'},
    {'code': 'deg15', 'name': 'Degrees (15°)'},
  ];

  // -------------------- Lifecycle --------------------
  @override
  void initState() {
    super.initState();
    _regPwdCtl.addListener(_validateRegisterForm);
    _regPwd2Ctl.addListener(_validateRegisterForm);
    _regEmailCtl.addListener(_validateRegisterForm);
    _regNicknameCtl.addListener(_validateRegisterForm);
    _regCodeCtl.addListener(_validateRegisterForm);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeStartupScreen();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _emailCtl.dispose();
    _pwdLoginCtl.dispose();
    _regEmailCtl.dispose();
    _regNicknameCtl.dispose();
    _regPwdCtl.dispose();
    _regPwd2Ctl.dispose();
    _regCodeCtl.dispose();
    super.dispose();
  }

  Future<void> _initializeStartupScreen() async {
    await ServerAddressService.applyToApi();
    await _loadUnitLanguageTurnModeToProvider();
    await _loadCachedProfileAndPrefs();
    await _tryAutoLogin();
  }

  // -------------------- Loaders --------------------
  Future<void> _loadUnitLanguageTurnModeToProvider() async {
    final sp = await SharedPreferences.getInstance();
    final unit = sp.getString('saved_unit') ?? "feet";
    final lang = sp.getString('saved_language') ?? "en";
    final turnMode = sp.getString('saved_turn_mode') ?? "default";
    final announceLocation = sp.getBool('saved_announce_location') ?? false;
    final provider = context.read<SettingsProvider>();
    await provider.setAll(
      language: lang, 
      unit: unit, 
      turnMode: turnMode,
      announceCurrentLocation: announceLocation,
    );
  }

  Future<void> _loadCachedProfileAndPrefs() async {
    final sp = await SharedPreferences.getInstance();
    setState(() {
      _cachedEmail = sp.getString('saved_email');
      _cachedNickname = sp.getString('saved_nickname');
      _cachedAvatarUrl = sp.getString('saved_avatar_url');
      _cachedUnit = sp.getString('saved_unit') ?? "feet";
      _cachedLanguage = sp.getString('saved_language') ?? "en";
    });
    final provider = context.read<SettingsProvider>();
    final turnMode = sp.getString('saved_turn_mode') ?? "default";
    final announceLocation = sp.getBool('saved_announce_location') ?? false;
    await provider.setAll(
      language: _cachedLanguage!, 
      unit: _cachedUnit!, 
      turnMode: turnMode,
      announceCurrentLocation: announceLocation,  // 新增
    );

    provider.setEmail(_cachedEmail ?? "");
    provider.setNickname(_cachedNickname ?? "");

    final localAvatarPath = sp.getString('saved_avatar_local');
    if (localAvatarPath != null && File(localAvatarPath).existsSync()) {
      _cachedAvatarFile = File(localAvatarPath);
      await provider.saveAvatar(_cachedAvatarFile!);
      setState(() => _avatarKey = UniqueKey());
    } else if (_cachedAvatarUrl != null && _cachedAvatarUrl!.isNotEmpty) {
      await provider.saveAvatarUrl(_cachedAvatarUrl!);
    }
  }

  Future<void> _downloadAndSaveAvatar(String avatarUrl) async {
    try {
      final httpClient = HttpClient();
      final req = await httpClient.getUrl(Uri.parse(avatarUrl));
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(resp);
        final dir = await getApplicationDocumentsDirectory();
        final localPath = '${dir.path}/avatar.jpg';
        final f = File(localPath);
        await f.writeAsBytes(bytes);
        final sp = await SharedPreferences.getInstance();
        await sp.setString('saved_avatar_local', localPath);
        setState(() {
          _cachedAvatarFile = f;
          _avatarKey = UniqueKey();
        });
        await context.read<SettingsProvider>().saveAvatar(f);
      }
    } catch (_) {
      // Ignore avatar download errors silently
    }
  }

  Future<void> _tryAutoLogin() async {
    final sp = await SharedPreferences.getInstance();
    final email = sp.getString('saved_email');
    final pwd = sp.getString('saved_password');
    final nickname = sp.getString('saved_nickname');
    final avatarUrl = sp.getString('saved_avatar_url');
    final unit = sp.getString('saved_unit') ?? "feet";
    final lang = sp.getString('saved_language') ?? "en";
    final turnMode = sp.getString('saved_turn_mode') ?? "default";
    final provider = context.read<SettingsProvider>();

    if (email != null && pwd != null) {
      // Sync ApiService with current server setting again
      await ServerAddressService.applyToApi();
      final resp = await ApiService.login(email, pwd);
      if (!resp.containsKey('error')) {
        provider.setEmail(email);
        provider.setNickname(resp['nickname'] ?? nickname ?? "");
        final newAvatarUrl = resp['avatar_url'] as String?;
        if (newAvatarUrl != null && newAvatarUrl.isNotEmpty) {
          final full = ServerAddressService.resolve(newAvatarUrl);
          await _downloadAndSaveAvatar(full);
          await provider.saveAvatarUrl(full);
          await _saveProfileAndPrefs(
            email, pwd, provider.nickname, full, unit, lang,
            turnMode: turnMode,
            avatarLocalPath: _cachedAvatarFile?.path,
          );
        } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
          await provider.saveAvatarUrl(ServerAddressService.resolve(avatarUrl));
        }
        await provider.setAll(language: lang, unit: unit, turnMode: turnMode);
        await provider.setLoggedIn(true);
        // Retry any trial uploads that were in flight when the app last
        // closed (or that previously failed because of network issues).
        unawaited(TrialRecorder.resumePendingUploads());
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
      setState(() => _showFullLogin = true);
    }
  }

  // -------------------- Persistence --------------------
  Future<void> _saveProfileAndPrefs(
    String email,
    String password,
    String? nickname,
    String? avatarUrl,
    String unit,
    String language, {
    String turnMode = "default",
    String? avatarLocalPath,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('saved_email', email);
    await sp.setString('saved_password', password);
    if (nickname != null) await sp.setString('saved_nickname', nickname);
    if (avatarUrl != null) await sp.setString('saved_avatar_url', avatarUrl);
    await sp.setString('saved_unit', unit);
    await sp.setString('saved_language', language);
    await sp.setString('saved_turn_mode', turnMode);
    if (avatarLocalPath != null) await sp.setString('saved_avatar_local', avatarLocalPath);
    setState(() {
      _cachedEmail = email;
      _cachedNickname = nickname;
      _cachedAvatarUrl = avatarUrl;
      _cachedUnit = unit;
      _cachedLanguage = language;
      // No separate local cache field for turn mode in this screen
    });
  }

  Future<void> _clearCachedProfileAndPrefs() async {
    final sp = await SharedPreferences.getInstance();
    final localAvatarPath = sp.getString('saved_avatar_local');
    if (localAvatarPath != null) {
      final file = File(localAvatarPath);
      if (await file.exists()) await file.delete();
      await sp.remove('saved_avatar_local');
    }
    await sp.remove('saved_email');
    await sp.remove('saved_password');
    await sp.remove('saved_nickname');
    await sp.remove('saved_avatar_url');
    await sp.remove('saved_unit');
    await sp.remove('saved_language');
    await sp.remove('saved_turn_mode');
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

  // -------------------- Auth Handlers --------------------
  Future<void> _handleLogin() async {
    final email = _emailCtl.text.trim();
    final pwd = _pwdLoginCtl.text;

    if (!email.contains('@') || email.isEmpty) {
      setState(() => _errorMsg = "Please enter a valid email address.");
      return;
    }
    if (pwd.isEmpty) {
      setState(() => _errorMsg = "Password cannot be empty.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    await ServerAddressService.applyToApi();

    final provider = context.read<SettingsProvider>();
    try {
      final resp = await ApiService.login(email, pwd);
      if (resp.containsKey("error")) {
        setState(() {
          _errorMsg = _backendErrorToText(resp["error"]);
          _isLoading = false;
        });
        return;
      }
      provider.setEmail(email);
      provider.setNickname(resp["nickname"] ?? "");
      final avatarUrl = resp['avatar_url'] as String?;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        final fullUrl = ServerAddressService.resolve(avatarUrl);
        await _downloadAndSaveAvatar(fullUrl);
        await provider.saveAvatarUrl(fullUrl);
        await _saveProfileAndPrefs(
          email,
          pwd,
          provider.nickname,
          fullUrl,
          provider.unit,
          provider.languageCode,
          turnMode: provider.turnMode,
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
    } catch (_) {
      setState(() {
        _errorMsg = "Network or server error!";
        _isLoading = false;
      });
    }
  }

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

    await ServerAddressService.applyToApi();

    final provider = context.read<SettingsProvider>();
    try {
      final resp = await ApiService.register(
        _regEmailCtl.text.trim(),
        _regNicknameCtl.text.trim(),
        _regPwdCtl.text,
        _regCodeCtl.text.trim(),
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
        _regEmailCtl.text.trim(),
        _regPwdCtl.text,
      );
      if (loginResp.containsKey("error")) {
        setState(() {
          _errorMsg = _backendErrorToText(loginResp["error"]);
          _isLoading = false;
        });
        return;
      }
      provider.setEmail(_regEmailCtl.text.trim());
      provider.setNickname(_regNicknameCtl.text.trim());

      final avatarUrl = loginResp['avatar_url'] as String?;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        final fullUrl = ServerAddressService.resolve(avatarUrl);
        await _downloadAndSaveAvatar(fullUrl);
        await provider.saveAvatarUrl(fullUrl);
        await _saveProfileAndPrefs(
          _regEmailCtl.text.trim(),
          _regPwdCtl.text,
          provider.nickname,
          fullUrl,
          provider.unit,
          provider.languageCode,
          turnMode: provider.turnMode,
          avatarLocalPath: _cachedAvatarFile?.path,
        );
        setState(() => _avatarKey = UniqueKey());
      } else if (provider.avatarUrl != null) {
        await provider.saveAvatarUrl(provider.avatarUrl!);
      }
      await _onAuthSuccess(
        _regEmailCtl.text.trim(),
        _regPwdCtl.text,
        provider.nickname,
        provider.avatarUrl,
        avatarLocalPath: _cachedAvatarFile?.path,
      );
    } catch (_) {
      setState(() {
        _errorMsg = "Network or server error!";
        _isLoading = false;
      });
    }
  }

  Future<void> _onAuthSuccess(
    String email,
    String password,
    String? nickname,
    String? avatarUrl, {
    String? avatarLocalPath,
  }) async {
    final provider = context.read<SettingsProvider>();
    await _saveProfileAndPrefs(
      email,
      password,
      nickname,
      avatarUrl,
      provider.unit,
      provider.languageCode,
      turnMode: provider.turnMode,
      avatarLocalPath: avatarLocalPath,
    );
    await ApiService.selectUnit(provider.unit);
    await ApiService.selectLanguage(provider.languageCode);
    await ApiService.selectTurnMode(provider.turnMode);
    await ApiService.setAnnounceLocation(provider.announceCurrentLocation);
    await provider.setLoggedIn(true);
    // Retry any trial uploads that were in flight when the app last closed
    // (or that previously failed because of network issues).
    unawaited(TrialRecorder.resumePendingUploads());
    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const NavigationModeScreen()),
      );
    }
  }

  Future<void> _logout() async {
    await ApiService.logout();
    await _clearCachedProfileAndPrefs();
    setState(() {
      _errorMsg = null;
      _showFullLogin = true;
    });
  }

  // -------------------- Avatar --------------------
  Future<void> _pickAvatar() async {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () async {
                Navigator.pop(ctx);
                final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90);
                if (picked != null) await _cropAndSetAvatar(File(picked.path));
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(ctx);
                final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
                if (picked != null) await _cropAndSetAvatar(File(picked.path));
              },
            ),
          ],
        ),
      ),
    );
  }

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
    final dir = await getApplicationDocumentsDirectory();
    final localAvatarPath = '${dir.path}/avatar.jpg';
    final localAvatarFile = await croppedFile.copy(localAvatarPath);

    final sp = await SharedPreferences.getInstance();
    await sp.setString('saved_avatar_local', localAvatarPath);
    final provider = context.read<SettingsProvider>();
    await provider.saveAvatar(localAvatarFile);

    setState(() {
      _cachedAvatarFile = localAvatarFile;
      _avatarKey = UniqueKey();
    });

    // Upload avatar
    final email = provider.email;
    if (email.isNotEmpty) {
      final bytes = await localAvatarFile.readAsBytes();
      final uploadResp = await ApiService.uploadAvatar(bytes, "avatar.jpg", email);
      final url = uploadResp['url'];
      if (url != null && (url as String).isNotEmpty) {
        final resolved = ServerAddressService.resolve(url);
        await provider.saveAvatarUrl(resolved);
        // Bust cache
        final withTs = '$resolved?t=${DateTime.now().millisecondsSinceEpoch}';
        await _downloadAndSaveAvatar(withTs);
        await _onAuthSuccess(
          email,
          _pwdLoginCtl.text,
          provider.nickname,
          resolved,
          avatarLocalPath: localAvatarPath,
        );
        setState(() => _avatarKey = UniqueKey());
      }
    }
  }

  // -------------------- Verification Code --------------------
  Future<void> _sendVerificationCode() async {
    final email = _regEmailCtl.text.trim();
    if (!email.contains('@')) {
      setState(() => _regCodeMsg = "Please enter a valid email address.");
      return;
    }
    setState(() {
      _regCodeMsg = null;
      _codeSent = false;
      _codeTimeout = 0;
    });

    await ServerAddressService.applyToApi();
    try {
      final resp = await ApiService.sendVerificationCode(email);
      if (resp.containsKey("msg")) {
        setState(() {
          _codeSent = true;
          _codeTimeout = 60;
          _regCodeMsg = "Verification code sent to $email.";
        });
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (t) {
          setState(() {
            _codeTimeout -= 1;
            if (_codeTimeout <= 0) t.cancel();
          });
        });
      } else if (resp.containsKey("error")) {
        setState(() => _regCodeMsg = _backendErrorToText(resp["error"]));
      } else {
        setState(() => _regCodeMsg = "Failed to send verification code.");
      }
    } catch (_) {
      setState(() => _regCodeMsg = "Network or server error.");
    }
  }

  // -------------------- Validation & mapping --------------------
  void _validateRegisterForm() {
    final email = _regEmailCtl.text.trim();
    final nickname = _regNicknameCtl.text.trim();
    final pwd1 = _regPwdCtl.text;
    final pwd2 = _regPwd2Ctl.text;
    final code = _regCodeCtl.text.trim();

    final isPwdMatch = pwd1.isNotEmpty && pwd2.isNotEmpty && pwd1 == pwd2;
    final isEmail = email.contains('@');
    final isNickname = nickname.isNotEmpty;
    final isPwdValid = pwd1.length >= 6;
    final isCode = code.isNotEmpty;

    setState(() {
      _isRegFormValid = isEmail && isNickname && isPwdValid && isPwdMatch;
      _isCodeFilled = isCode;
      _regPwdMismatchMsg = (!isPwdMatch && pwd2.isNotEmpty) ? "Passwords do not match!" : null;
    });
  }

  String _backendErrorToText(String error) {
    switch (error) {
      case "user_exists":
        return "User already exists.";
      case "invalid_or_expired_code":
        return "Invalid or expired verification code.";
      case "empty_field":
        return "Please complete all fields.";
      case "incorrect_credentials":
        return "Incorrect email or password.";
      case "invalid_email":
        return "Invalid email address.";
      default:
        return error;
    }
  }

  // -------------------- Small UI Pieces --------------------
  Widget _unitSelector() {
    final provider = context.watch<SettingsProvider>();
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Unit:", style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () async {
              await provider.setUnit('feet');
            },
            style: OutlinedButton.styleFrom(
              backgroundColor: provider.unit == "feet" ? Colors.blueAccent : Colors.transparent,
            ),
            child: Text(
              "Feet",
              style: TextStyle(
                color: provider.unit == "feet" ? Colors.white : Colors.black87,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () async {
              await provider.setUnit('meter');
            },
            style: OutlinedButton.styleFrom(
              backgroundColor: provider.unit == "meter" ? Colors.blueAccent : Colors.transparent,
            ),
            child: Text(
              "Meter",
              style: TextStyle(
                color: provider.unit == "meter" ? Colors.white : Colors.black87,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _languageSelector() {
    final provider = context.watch<SettingsProvider>();
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Language:", style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: provider.languageCode,
            items: _languages
                .map((lang) => DropdownMenuItem(
                      value: lang['code'],
                      child: Text(lang['name'] ?? ""),
                    ))
                .toList(),
            onChanged: (String? value) async {
              if (value != null) {
                await provider.setLanguage(value);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _turnModeSelector() {
    final provider = context.watch<SettingsProvider>();
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Turn Mode:", style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          ..._turnModes.map((m) {
            final code = m['code']!;
            final name = m['name']!;
            final isSelected = provider.turnMode == code;
            return Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: OutlinedButton(
                onPressed: () async {
                  await provider.setTurnMode(code);
                },
                style: OutlinedButton.styleFrom(
                  backgroundColor: isSelected ? Colors.blueAccent : Colors.transparent,
                ),
                child: Text(
                  name,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _announceLocationToggle() {
    final provider = context.watch<SettingsProvider>();
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Announce Location:", style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Switch(
            value: provider.announceCurrentLocation,
            onChanged: (bool value) async {
              await provider.setAnnounceCurrentLocation(value);
            },
            activeColor: Colors.blueAccent,
          ),
          Text(
            provider.announceCurrentLocation ? "ON" : "OFF",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: provider.announceCurrentLocation ? Colors.blueAccent : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------- Forms --------------------
  Widget _buildLoginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text("Welcome to UNav", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        // Server selector + editable address
        ServerSelector(onChanged: (_) {}),
        const SizedBox(height: 16),

        TextField(
          controller: _emailCtl,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: "Email",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwdLoginCtl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Password",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        const SizedBox(height: 16),
        _unitSelector(),
        const SizedBox(height: 12),
        _languageSelector(),
        const SizedBox(height: 12),
        _turnModeSelector(),
        const SizedBox(height: 12),
        _announceLocationToggle(),
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

  Widget _buildRegisterForm() {
    final sendCodeEnabled = _isRegFormValid && !_codeSent && _codeTimeout == 0;
    final registerEnabled = _isRegFormValid && _isCodeFilled && !_isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text("Register for UNav", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        ServerSelector(onChanged: (_) {}),
        const SizedBox(height: 16),

        TextField(
          controller: _regEmailCtl,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: "Email",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _regNicknameCtl,
          decoration: const InputDecoration(
            labelText: "Nickname",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _regPwdCtl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Password",
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _regPwd2Ctl,
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
                controller: _regCodeCtl,
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
        const SizedBox(height: 16),
        _unitSelector(),
        const SizedBox(height: 12),
        _languageSelector(),
        const SizedBox(height: 12),
        _turnModeSelector(),
        const SizedBox(height: 12),
        _announceLocationToggle(),
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

  // -------------------- Build --------------------
  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final avatarFile = sp.avatarFile ?? _cachedAvatarFile;
    final avatarUrl = (sp.avatarUrl != null && sp.avatarUrl!.isNotEmpty)
        ? sp.avatarUrl!
        : (_cachedAvatarUrl ?? "");

    // If logged in and not in register/full-login mode: show quick entry
    if ((sp.isLoggedIn) && !_registerMode && !_showFullLogin) {
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
                sp.nickname.isNotEmpty
                    ? sp.nickname
                    : sp.email.isNotEmpty
                        ? sp.email
                        : (_cachedNickname ?? _cachedEmail ?? ""),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: ServerSelector(onChanged: (_) {}),
              ),
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

    // Login / Register page
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
                    : (avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) as ImageProvider : null),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _registerMode ? _buildRegisterForm() : _buildLoginForm(),
            ],
          ),
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
                  onPressed: () => setState(() => _registerMode = true),
                  child: const Text("No account? Register", style: TextStyle(fontSize: 16)),
                ),
              if (_registerMode)
                TextButton(
                  onPressed: () => setState(() => _registerMode = false),
                  child: const Text("Already registered? Login", style: TextStyle(fontSize: 16)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------- Enter with auto login --------------------
  Future<void> _enterAppWithAutoLogin() async {
    final provider = context.read<SettingsProvider>();
    final sp = await SharedPreferences.getInstance();
    final email = sp.getString('saved_email');
    final pwd = sp.getString('saved_password');
    final nickname = sp.getString('saved_nickname');
    final avatarUrl = sp.getString('saved_avatar_url');
    final localAvatarPath = sp.getString('saved_avatar_local');
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

    await ServerAddressService.applyToApi();

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
    final serverAvatarUrl = resp['avatar_url'] as String?;
    if (serverAvatarUrl != null && serverAvatarUrl.isNotEmpty) {
      final fullUrl = ServerAddressService.resolve(serverAvatarUrl);
      await _downloadAndSaveAvatar(fullUrl);
      await provider.saveAvatarUrl(fullUrl);
      setState(() => _avatarKey = UniqueKey());
    } else if (localAvatarPath != null && File(localAvatarPath).existsSync()) {
      await provider.saveAvatar(File(localAvatarPath));
    } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
      await provider.saveAvatarUrl(ServerAddressService.resolve(avatarUrl));
    }
    await _onAuthSuccess(
      email,
      pwd,
      provider.nickname,
      provider.avatarUrl,
      avatarLocalPath: localAvatarPath,
    );
  }
}
