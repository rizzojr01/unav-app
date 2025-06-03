import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../api/api_service.dart';
import 'place_select_screen.dart';
import '../providers/settings_provider.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  // Controllers for login/register fields
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _loginPwdController = TextEditingController();
  final TextEditingController _regEmailController = TextEditingController();
  final TextEditingController _regPwdController = TextEditingController();
  final TextEditingController _regPwd2Controller = TextEditingController();
  final TextEditingController _regCodeController = TextEditingController();

  // UI State
  String? _serverAddress;
  String? _errorMsg;
  String? _regPwdMismatchMsg;
  String? _regCodeMsg;
  bool _isLoading = false;
  bool _registerMode = false;

  // Verification code
  bool _codeSent = false;
  int _codeTimeout = 0;
  Timer? _timer;

  bool _isRegFormValid = false;
  bool _isCodeFilled = false;

  final List<Map<String, String>> _languages = [
    {'code': 'en', 'name': 'English'},
    {'code': 'zh', 'name': '中文'},
    {'code': 'th', 'name': 'ไทย'},
  ];

  @override
  void initState() {
    super.initState();
    _loadServerAddress();
    _loadCredentials();
    _loadUnitAndLanguageToProvider();
    _regPwdController.addListener(_validateRegisterForm);
    _regPwd2Controller.addListener(_validateRegisterForm);
    _regEmailController.addListener(_validateRegisterForm);
    _regCodeController.addListener(_validateRegisterForm);
  }

  /// Load server address
  Future<void> _loadServerAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString("server_address") ?? "http://unav.zapto.org:5001";
    ApiService.setServer(saved);
    setState(() => _serverAddress = saved);
  }

  /// Save server address
  Future<void> _saveServerAddress(String addr) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_address", addr);
    ApiService.setServer(addr);
    setState(() => _serverAddress = addr);
  }

  /// Load credentials from local storage
  Future<void> _loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString('saved_email');
    final pwd = prefs.getString('saved_password');
    if (email != null && pwd != null) {
      setState(() {
        _emailController.text = email;
        _loginPwdController.text = pwd;
      });
    }
  }

  /// Save credentials to local storage (for auto-fill)
  Future<void> _saveCredentials(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_email', email);
    await prefs.setString('saved_password', password);
  }

  /// Clear saved credentials (for logout etc)
  Future<void> _clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_email');
    await prefs.remove('saved_password');
  }

  /// Loads saved unit and language from storage into Provider
  Future<void> _loadUnitAndLanguageToProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final unit = prefs.getString('saved_unit') ?? "feet";
    final lang = prefs.getString('saved_language') ?? "en";
    final provider = context.read<SettingsProvider>();
    provider.setAll(language: lang, unit: unit);
  }

  /// Saves current unit and language from Provider to local storage
  Future<void> _saveUnitAndLanguageFromProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = context.read<SettingsProvider>();
    await prefs.setString('saved_unit', provider.unit);
    await prefs.setString('saved_language', provider.languageCode);
  }

  /// Switches between login and register modes
  void _switchMode(bool toRegister) {
    setState(() {
      _registerMode = toRegister;
      _errorMsg = null;
      _regPwdMismatchMsg = null;
      _regCodeMsg = null;
      _regEmailController.clear();
      _regPwdController.clear();
      _regPwd2Controller.clear();
      _regCodeController.clear();
      _isRegFormValid = false;
      _isCodeFilled = false;
      _timer?.cancel();
      _codeTimeout = 0;
      _codeSent = false;
    });
  }

  /// Sends verification code
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

  /// Handles login (Provider: global language/unit)
  Future<void> _handleLogin() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    await _saveServerAddress(_serverAddress ?? "http://unav.zapto.org:5001");
    final provider = context.read<SettingsProvider>();
    try {
      final resp = await ApiService.login(
        _emailController.text.trim(),
        _loginPwdController.text,
      );
      if (resp.containsKey("error")) {
        setState(() {
          _errorMsg = _backendErrorToText(resp["error"]);
          _isLoading = false;
        });
        return;
      }
      await _saveCredentials(_emailController.text.trim(), _loginPwdController.text);
      await ApiService.selectUnit(provider.unit);
      await ApiService.selectLanguage(provider.languageCode);
      await _saveUnitAndLanguageFromProvider();
      if (context.mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PlaceSelectScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _errorMsg = "Network or server error!";
        _isLoading = false;
      });
    }
  }

  /// Handles registration
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
      await _saveCredentials(_regEmailController.text.trim(), _regPwdController.text);
      await ApiService.selectUnit(provider.unit);
      await ApiService.selectLanguage(provider.languageCode);
      await _saveUnitAndLanguageFromProvider();
      if (context.mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PlaceSelectScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _errorMsg = "Network or server error!";
        _isLoading = false;
      });
    }
  }

  /// Register form live validation
  void _validateRegisterForm() {
    String email = _regEmailController.text.trim();
    String pwd1 = _regPwdController.text;
    String pwd2 = _regPwd2Controller.text;
    String code = _regCodeController.text.trim();

    bool isPwdMatch = pwd1.isNotEmpty && pwd2.isNotEmpty && pwd1 == pwd2;
    bool isEmail = email.contains('@');
    bool isPwdValid = pwd1.length >= 6;
    bool isCode = code.isNotEmpty;
    setState(() {
      _isRegFormValid = isEmail && isPwdValid && isPwdMatch;
      _isCodeFilled = isCode;
      _regPwdMismatchMsg = (!isPwdMatch && pwd2.isNotEmpty) ? "Passwords do not match!" : null;
    });
  }

  /// Converts backend error code to human readable string.
  String _backendErrorToText(String error) {
    switch (error) {
      case "user_exists":
        return "User already exists.";
      case "invalid_or_expired_code":
        return "Invalid or expired verification code.";
      case "empty_field":
        return "Please complete all fields.";
      case "incorrect_credentials":
        return "Incorrect username or password.";
      case "invalid_email":
        return "Invalid email address.";
      default:
        return error;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _loginPwdController.dispose();
    _regEmailController.dispose();
    _regPwdController.dispose();
    _regPwd2Controller.dispose();
    _regCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('UNav'),
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
                  onPressed: () => _switchMode(true),
                  child: const Text("No account? Register", style: TextStyle(fontSize: 16)),
                ),
              if (_registerMode)
                TextButton(
                  onPressed: () => _switchMode(false),
                  child: const Text("Already registered? Login", style: TextStyle(fontSize: 16)),
                ),
            ],
          ),
        ),
      ),
    );
  }

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
              child: Text(_codeTimeout > 0 ? "Resend (${_codeTimeout}s)" : "Send Code"),
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

  Widget _unitSelector() {
    final provider = context.watch<SettingsProvider>();
    return Row(
      children: [
        const Text("Unit:", style: TextStyle(fontSize: 18)),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => provider.setUnit('feet'),
          style: OutlinedButton.styleFrom(
            backgroundColor: provider.unit == "feet" ? Colors.blueAccent : Colors.transparent,
          ),
          child: Text("Feet", style: TextStyle(color: provider.unit == "feet" ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => provider.setUnit('meter'),
          style: OutlinedButton.styleFrom(
            backgroundColor: provider.unit == "meter" ? Colors.blueAccent : Colors.transparent,
          ),
          child: Text("Meter", style: TextStyle(color: provider.unit == "meter" ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

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
          onChanged: (String? value) {
            if (value != null) {
              provider.setLanguage(value);
            }
          },
        ),
      ],
    );
  }
}
