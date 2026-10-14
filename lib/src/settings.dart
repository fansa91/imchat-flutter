import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

const String defaultServer = 'https://im.fansa.ccwu.cc';

/// 应用设置：服务器地址（当前 + 历史列表）、主题模式、登录令牌。
/// 令牌优先存 flutter_secure_storage（Keychain / Keystore / libsecret / DPAPI），
/// 安全存储不可用时（例如未签名的 macOS 构建没有钥匙串权限）退回 shared_preferences。
class Settings extends ChangeNotifier {
  Settings._(this._prefs);

  static const _kServer = 'im.server';
  static const _kServers = 'im.servers';
  static const _kTheme = 'im.theme';
  static const _kToken = 'im.token';
  static const _kTokenFallback = 'im.token.fallback';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  String _server = defaultServer;
  List<String> _servers = [defaultServer];
  ThemeMode _themeMode = ThemeMode.system;
  String _token = '';

  String get server => _server;
  List<String> get servers => List.unmodifiable(_servers);
  ThemeMode get themeMode => _themeMode;
  String get token => _token;

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = Settings._(prefs);
    s._server = prefs.getString(_kServer) ?? defaultServer;
    final list = prefs.getStringList(_kServers) ?? const [];
    s._servers = {defaultServer, ...list, s._server}.toList();
    s._themeMode = switch (prefs.getString(_kTheme)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    s._token = await s._readToken();
    return s;
  }

  // 令牌按服务器区分，切换服务器不会串号
  String get _tokenKey => '$_kToken@$_server';

  Future<String> _readToken() async {
    try {
      final t = await _secure.read(key: _tokenKey);
      if (t != null && t.isNotEmpty) return t;
    } catch (_) {}
    return _prefs.getString('$_kTokenFallback@$_server') ?? '';
  }

  Future<void> setToken(String t) async {
    _token = t;
    final fallbackKey = '$_kTokenFallback@$_server';
    try {
      if (t.isEmpty) {
        await _secure.delete(key: _tokenKey);
      } else {
        await _secure.write(key: _tokenKey, value: t);
      }
      await _prefs.remove(fallbackKey);
    } catch (_) {
      if (t.isEmpty) {
        await _prefs.remove(fallbackKey);
      } else {
        await _prefs.setString(fallbackKey, t);
      }
    }
  }

  /// 切换当前服务器（登录页使用），并加入历史列表
  Future<void> setServer(String input) async {
    final s = normalizeServer(input);
    if (s.isEmpty) return;
    _server = s;
    if (!_servers.contains(s)) _servers = [..._servers, s];
    await _prefs.setString(_kServer, s);
    await _prefs.setStringList(_kServers, _servers);
    _token = await _readToken();
    notifyListeners();
  }

  Future<void> removeServer(String s) async {
    if (s == defaultServer) return;
    _servers = _servers.where((x) => x != s).toList();
    await _prefs.setStringList(_kServers, _servers);
    if (_server == s) {
      await setServer(defaultServer);
    } else {
      notifyListeners();
    }
  }

  Future<void> setThemeMode(ThemeMode m) async {
    _themeMode = m;
    await _prefs.setString(_kTheme, switch (m) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
    notifyListeners();
  }

  /// 群公告“已关闭”标记（与 web 的 im.ann.{id} 一致）
  String? annDismissed(int cid) => _prefs.getString('im.ann.$_server.$cid');
  Future<void> dismissAnn(int cid, String at) => _prefs.setString('im.ann.$_server.$cid', at);
}
