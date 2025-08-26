import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tts_service.dart';
import '../providers/settings_provider.dart';
import '../api/api_service.dart';        // Import your ApiService
import 'startup_screen.dart';           // Import your StartupScreen

typedef FutureListString = Future<List<String>> Function();
typedef OnSelectCallback = void Function(String selected);

const Map<String, Map<String, String>> selectionPrompts = {
  'place': {
    'en': "Please select a place.",
    'zh': "请选择地点",
    'th': "โปรดเลือกสถานที่",
  },
  'building': {
    'en': "Please select a building.",
    'zh': "请选择楼宇",
    'th': "โปรดเลือกอาคาร",
  },
  'floor': {
    'en': "Please select a floor.",
    'zh': "请选择楼层",
    'th': "โปรดเลือกชั้น",
  },
  'destination': {
    'en': "Please select a destination.",
    'zh': "请选择目的地",
    'th': "โปรดเลือกจุดหมาย",
  },
};

class SelectScreen extends StatefulWidget {
  final String title;
  final String selectionType;
  final FutureListString fetchOptions;
  final OnSelectCallback onSelect;
  final String? customSelectionPrompt;

  const SelectScreen({
    super.key,
    required this.title,
    required this.selectionType,
    required this.fetchOptions,
    required this.onSelect,
    this.customSelectionPrompt,
  });

  @override
  State<SelectScreen> createState() => _SelectScreenState();
}

class _SelectScreenState extends State<SelectScreen> {
  List<String> options = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _speakPrompt();
    _loadOptions();
  }

  String _getPromptText(String lang) {
    return selectionPrompts[widget.selectionType]?[lang] ??
        selectionPrompts[widget.selectionType]?['en'] ??
        "";
  }

  Future<void> _speakPrompt() async {
    final lang = context.read<SettingsProvider>().languageCode;
    final prompt = _getPromptText(lang);
    await TTSService.setLanguage(lang);
    await TTSService.speak(prompt);
  }

  Future<void> _loadOptions() async {
    final result = await widget.fetchOptions();
    setState(() {
      options = result;
      isLoading = false;
    });
  }

  String _getSelectionPrompt(String val, String lang) {
    if (widget.customSelectionPrompt != null) {
      return widget.customSelectionPrompt!.replaceAll(r"{val}", val);
    }
    switch (lang) {
      case 'zh':
        return "你选择了 $val";
      case 'th':
        return "คุณเลือก $val";
      case 'en':
      default:
        return "You selected $val";
    }
  }

  Future<void> _handleSelect(String val) async {
    final lang = context.read<SettingsProvider>().languageCode;
    await TTSService.setLanguage(lang);
    await TTSService.speak(_getSelectionPrompt(val, lang));
    widget.onSelect(val);
  }

  /// Handles logout: calls API, clears provider data, and navigates to login page.
  Future<void> _handleLogout() async {
    await ApiService.logout();
    if (context.mounted) {
      // Optionally clear provider/user data here if needed
      // context.read<SettingsProvider>().clearUserInfo();

      // Pop all routes and go back to login screen
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const StartupScreen()),
        (route) => false,
      );
    }
  }

  Widget _buildAvatar() {
    final settingsProvider = context.watch<SettingsProvider>();
    final avatarFile = settingsProvider.avatarFile;
    final avatarUrl = settingsProvider.avatarUrl;
    return Padding(
      padding: const EdgeInsets.only(right: 16.0),
      child: CircleAvatar(
        backgroundImage: avatarFile != null
            ? FileImage(avatarFile)
            : (avatarUrl != null
                ? NetworkImage(avatarUrl) as ImageProvider
                : null),
        child: (avatarFile == null && avatarUrl == null)
            ? const Icon(Icons.person, color: Colors.white)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Logout",
            onPressed: _handleLogout,
          ),
          title: Text(widget.title),
          actions: [_buildAvatar()],
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.logout),
          tooltip: "Logout",
          onPressed: _handleLogout,
        ),
        title: Text(widget.title),
        actions: [_buildAvatar()],
      ),
      body: ListView.builder(
        itemCount: options.length,
        itemBuilder: (context, idx) {
          final option = options[idx];
          return ListTile(
            title: Text(option, style: const TextStyle(fontSize: 28)),
            onTap: () => _handleSelect(option),
          );
        },
      ),
    );
  }
}
