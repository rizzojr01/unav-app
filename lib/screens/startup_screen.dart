import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_service.dart';
import 'place_select_screen.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  final TextEditingController _serverController =
      TextEditingController(text: "http://unav.zapto.org:5001");
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  String? _errorMsg;
  bool _isLoading = false;
  String _unit = "feet"; // Default unit

  @override
  void initState() {
    super.initState();
    _loadServerAddress();
  }

  /// Loads server address from local storage if available
  Future<void> _loadServerAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString("server_address");
    if (saved != null) {
      _serverController.text = saved;
      ApiService.setServer(saved);
    }
  }

  /// Saves server address and updates ApiService endpoint
  Future<void> _saveServerAddress(String server) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_address", server);
    ApiService.setServer(server);
  }

  /// Toggles unit between 'feet' and 'meter'
  void _toggleUnit() {
    setState(() {
      _unit = _unit == "feet" ? "meter" : "feet";
    });
  }

  /// Handles login logic and navigation
  Future<void> _handleLogin() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    await _saveServerAddress(_serverController.text.trim());
    try {
      final resp = await ApiService.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );
      if (resp.containsKey("error")) {
        setState(() {
          if (resp["error"].toString().contains("not found")) {
            _errorMsg = "User does not exist!";
          } else if (resp["error"].toString().contains("incorrect")) {
            _errorMsg = "Incorrect password!";
          } else {
            _errorMsg = resp["error"];
          }
          _isLoading = false;
        });
        return;
      }
      // Set unit after login
      await ApiService.selectUnit(_unit);

      // Login success: jump to place selection
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

  /// Handles register logic and navigation
  Future<void> _handleRegister() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    await _saveServerAddress(_serverController.text.trim());
    try {
      final resp = await ApiService.register(
        _usernameController.text.trim(),
        _passwordController.text,
      );
      if (resp.containsKey("error")) {
        setState(() {
          if (resp["error"].toString().contains("exists")) {
            _errorMsg = "User already exists!";
          } else {
            _errorMsg = resp["error"];
          }
          _isLoading = false;
        });
        return;
      }
      // Login after register
      await ApiService.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );
      // Set unit after registration
      await ApiService.selectUnit(_unit);

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('UNav Login/Register'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                "Welcome to UNav",
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              // Server address input
              TextField(
                controller: _serverController,
                decoration: const InputDecoration(
                  labelText: "Server Address",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.cloud),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: "Username",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Password",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text("Unit:", style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _toggleUnit,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _unit == "feet"
                          ? Colors.blueAccent
                          : Colors.transparent,
                    ),
                    child: Text(
                      "Feet",
                      style: TextStyle(
                        color: _unit == "feet" ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _toggleUnit,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _unit == "meter"
                          ? Colors.blueAccent
                          : Colors.transparent,
                    ),
                    child: Text(
                      "Meter",
                      style: TextStyle(
                        color: _unit == "meter" ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (_errorMsg != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    _errorMsg!,
                    style: const TextStyle(color: Colors.red, fontSize: 18),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    child: const Text("Login"),
                  ),
                  const SizedBox(width: 24),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _handleRegister,
                    child: const Text("Register"),
                  ),
                ],
              ),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
