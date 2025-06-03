import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tts_service.dart';
import '../providers/settings_provider.dart';

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
  final String selectionType; // 'place'/'building'/'floor'/'destination'
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
    // Fallback to English if not found
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


  /// Load selectable options asynchronously.
  Future<void> _loadOptions() async {
    var result = await widget.fetchOptions();
    setState(() {
      options = result;
      isLoading = false;
    });
  }

  /// Generate a default selection prompt in the user's language.
  String _getSelectionPrompt(String val, String lang) {
    if (widget.customSelectionPrompt != null) {
      // If a custom prompt is provided, use it.
      return widget.customSelectionPrompt!.replaceAll(r"{val}", val);
    }
    switch (lang) {
      case 'zh':
        return "你选择了 $val";
      case 'th':
        return "คุณเลือก $val"; // Thai for "You selected"
      case 'en':
      default:
        return "You selected $val";
    }
  }

  /// Handles item selection: speak and invoke callback.
  Future<void> _handleSelect(String val) async {
    final lang = context.read<SettingsProvider>().languageCode;
    await TTSService.setLanguage(lang);
    await TTSService.speak(_getSelectionPrompt(val, lang));
    widget.onSelect(val);
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
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
