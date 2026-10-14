import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';

enum ConnState { connecting, online, offline }

typedef WsHandler = void Function(dynamic data, String? id);

/// WebSocket 封装：自动重连（指数退避 + 抖动）、20 秒心跳、按 type 分发。
/// 帧格式：{"type": ..., "id": ..., "data": {...}}（见 imserver/internal/ws/protocol.go）
class ChatSocket {
  ChatSocket({required this.server, required this.token});

  String Function() server;
  String Function() token;

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  final _handlers = <String, Set<WsHandler>>{};
  int _retry = 0;
  Timer? _timer;
  Timer? _ping;
  bool _stopped = true;
  bool _open = false;
  final _rand = Random();

  void Function(ConnState s) onStatus = (_) {};
  void Function() onOpen = () {};

  bool get isOpen => _open;

  void start() {
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _ping?.cancel();
    _closeChannel();
  }

  void _closeChannel() {
    _open = false;
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }

  void Function() on(String type, WsHandler h) {
    _handlers.putIfAbsent(type, () => <WsHandler>{}).add(h);
    return () => _handlers[type]?.remove(h);
  }

  bool send(String type, Object? data, [String? id]) {
    if (!_open || _ch == null) return false;
    try {
      _ch!.sink.add(jsonEncode({'type': type, 'id': ?id, 'data': data ?? {}}));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 回到前台 / 网络恢复时立即重连
  void kick() {
    if (_stopped) return;
    if (_ch == null) {
      _timer?.cancel();
      _retry = 0;
      _connect();
    }
  }

  Future<void> _connect() async {
    if (_stopped) return;
    onStatus(ConnState.connecting);
    final uri = wsUri(server(), token());
    final ch = WebSocketChannel.connect(uri);
    _ch = ch;
    _sub = ch.stream.listen(
      _onData,
      onError: (_) => _onClosed(ch),
      onDone: () => _onClosed(ch),
      cancelOnError: true,
    );
    try {
      await ch.ready.timeout(const Duration(seconds: 15));
    } catch (_) {
      _onClosed(ch);
      return;
    }
    if (_ch != ch) return;
    _open = true;
    _retry = 0;
    onStatus(ConnState.online);
    _ping?.cancel();
    _ping = Timer.periodic(const Duration(seconds: 20), (_) => send('ping', {}));
    onOpen();
  }

  void _onData(dynamic raw) {
    Map<String, dynamic> env;
    try {
      final d = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (d is! Map<String, dynamic>) return;
      env = d;
    } catch (_) {
      return;
    }
    final type = env['type'];
    if (type is! String) return;
    final hs = _handlers[type];
    if (hs == null) return;
    for (final h in hs.toList()) {
      try {
        h(env['data'], env['id'] as String?);
      } catch (_) {}
    }
  }

  void _onClosed(WebSocketChannel ch) {
    if (_ch != ch) return;
    _ping?.cancel();
    _closeChannel();
    if (_stopped) return;
    onStatus(ConnState.offline);
    final base = min(30000, 1000 * pow(2, _retry).toInt());
    final delay = (base * (0.7 + _rand.nextDouble() * 0.6)).round();
    _retry = min(_retry + 1, 16);
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: delay), _connect);
  }
}
