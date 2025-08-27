// lib/widgets/server_selector.dart
import 'package:flutter/material.dart';
import '../services/server_address_service.dart';

typedef OnServerChanged = void Function(ServerAddressState state);

class ServerSelector extends StatefulWidget {
  final OnServerChanged? onChanged;
  final String? label; // 可自定义标题

  const ServerSelector({super.key, this.onChanged, this.label});

  @override
  State<ServerSelector> createState() => _ServerSelectorState();
}

class _ServerSelectorState extends State<ServerSelector> {
  late TextEditingController _addrCtl;
  String _key = ServerAddressService.kDefaultKey;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _addrCtl = TextEditingController();
    _init();
  }

  Future<void> _init() async {
    final state = await ServerAddressService.applyToApi();
    setState(() {
      _key = state.key;
      _addrCtl.text = state.address;
      _loading = false;
    });
    widget.onChanged?.call(state);
  }

  @override
  void dispose() {
    _addrCtl.dispose();
    super.dispose();
  }

  Future<void> _changeKey(String? newKey) async {
    if (newKey == null) return;
    final state = await ServerAddressService.saveKey(newKey);
    setState(() {
      _key = state.key;
      _addrCtl.text = state.address; // 预填默认地址，但文本框保持可编辑
    });
    widget.onChanged?.call(state);
  }

  Future<void> _saveAddress() async {
    final state = await ServerAddressService.saveAddress(_addrCtl.text);
    widget.onChanged?.call(state);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server address saved')));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label ?? 'Server', style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 8),
        Row(
          children: [
            DropdownButton<String>(
              value: _key,
              items: ServerAddressService.kDefaults.keys
                  .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                  .toList(),
              onChanged: _changeKey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _addrCtl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'Base URL',
                  hintText: 'http://host:port',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _saveAddress, child: const Text('Save')),
          ],
        ),
      ],
    );
  }
}
