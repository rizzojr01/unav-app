import 'package:flutter/material.dart';
import '../services/tts_service.dart';

typedef FutureListString = Future<List<String>> Function();
typedef OnSelectCallback = void Function(String selected);

class SelectScreen extends StatefulWidget {
  final String title;               // 页面标题
  final String promptText;          // 语音/页面提示文本
  final FutureListString fetchOptions; // 异步加载选项的方法
  final OnSelectCallback onSelect;      // 选中后的回调

  const SelectScreen({
    super.key,
    required this.title,
    required this.promptText,
    required this.fetchOptions,
    required this.onSelect,
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
    TTSService.speak(widget.promptText);
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    var result = await widget.fetchOptions();
    setState(() {
      options = result;
      isLoading = false;
    });
  }

  void _handleSelect(String val) {
    TTSService.speak("You selected $val");
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
            onLongPress: () {
              // 这里可以扩展为语音输入
            },
          );
        },
      ),
    );
  }
}
