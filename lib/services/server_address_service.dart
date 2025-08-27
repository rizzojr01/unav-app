// lib/services/server_address_service.dart
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_service.dart';

class ServerAddressState {
  final String key;     // e.g. "NYU" / "MU"
  final String address; // 完整Base URL，如 http://xxx:5001
  const ServerAddressState({required this.key, required this.address});
}

class ServerAddressService {
  /// 可集中维护默认映射（可随时加学校）
  static const Map<String, String> kDefaults = {
    'NYU': 'http://unav.zapto.org:5001',
    'MU' : 'http://mu-tau.ddns.net:5001',
  };

  static const String kDefaultKey = 'NYU';
  static const String _kSavedKey = 'saved_server_key';
  static const String _kSavedAddr = 'server_address';

  /// 裁剪末尾的斜杠，保持统一
  static String normalizeBase(String base) {
    final b = base.trim();
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  /// 解析相对路径：给后端回 avatar_url/接口路径时调用
  static String resolve(String url, {String? base}) {
    if (url.startsWith('http')) return url;
    final b = normalizeBase(base ?? kDefaults[kDefaultKey]!);
    return '$b$url';
  }

  /// 读取持久化；若无记录则回落到默认项
  static Future<ServerAddressState> load() async {
    final sp = await SharedPreferences.getInstance();
    final savedKey = sp.getString(_kSavedKey) ?? kDefaultKey;
    final base = sp.getString(_kSavedAddr) ?? kDefaults[savedKey] ?? kDefaults[kDefaultKey]!;
    return ServerAddressState(key: kDefaults.containsKey(savedKey) ? savedKey : kDefaultKey, address: normalizeBase(base));
  }

  /// 保存“院校Key”并将其默认地址写入 address
  static Future<ServerAddressState> saveKey(String key) async {
    final sp = await SharedPreferences.getInstance();
    final base = normalizeBase(kDefaults[key] ?? kDefaults[kDefaultKey]!);
    await sp.setString(_kSavedKey, key);
    await sp.setString(_kSavedAddr, base);
    await _applyToApi(base);
    return ServerAddressState(key: key, address: base);
  }

  /// 保存“可编辑地址”；不改院校Key
  static Future<ServerAddressState> saveAddress(String address) async {
    final sp = await SharedPreferences.getInstance();
    final state = await load();
    final norm = normalizeBase(address);
    await sp.setString(_kSavedAddr, norm);
    await _applyToApi(norm);
    return ServerAddressState(key: state.key, address: norm);
  }

  /// 启动/登录前调用：让 ApiService 用上当前地址
  static Future<ServerAddressState> applyToApi() async {
    final state = await load();
    await _applyToApi(state.address);
    return state;
  }

  static Future<void> _applyToApi(String base) async {
    ApiService.setServer(base);
  }
}
