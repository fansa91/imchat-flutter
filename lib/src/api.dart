import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiError implements Exception {
  final int status;
  final String code;
  final String message;
  ApiError(this.status, this.code, this.message);
  @override
  String toString() => message;
}

/// 规范化服务器地址：补全协议、去掉末尾的 /
String normalizeServer(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// http(s)://host -> ws(s)://host/ws?token=...
Uri wsUri(String server, String token) {
  final base = Uri.parse(normalizeServer(server));
  final scheme = base.scheme == 'https' ? 'wss' : 'ws';
  final path = '${base.path}/ws';
  return base.replace(scheme: scheme, path: path, queryParameters: {'token': token});
}

/// REST 客户端（与 imweb/src/api.ts 一一对应）
class Api {
  String server;
  String token;
  void Function()? onUnauthorized;
  final http.Client _client;

  Api({required this.server, this.token = '', http.Client? client}) : _client = client ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(normalizeServer(server));
    return base.replace(path: '${base.path}$path', queryParameters: (query == null || query.isEmpty) ? null : query);
  }

  Future<dynamic> _req(String method, String path,
      {Object? body, Map<String, String>? query, Duration timeout = const Duration(seconds: 20)}) async {
    final req = http.Request(method, _uri(path, query));
    req.headers['Content-Type'] = 'application/json';
    if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } catch (_) {
      throw ApiError(0, 'network', '网络连接失败');
    }
    dynamic data;
    try {
      data = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      data = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      if (res.statusCode == 401 && token.isNotEmpty) onUnauthorized?.call();
      final m = data is Map ? data : const {};
      throw ApiError(
        res.statusCode,
        (m['code'] ?? 'error').toString(),
        (m['message'] ?? '请求失败 (${res.statusCode})').toString(),
      );
    }
    return data;
  }

  Map<String, dynamic> _map(dynamic d) => d is Map<String, dynamic> ? d : <String, dynamic>{};
  List<dynamic> _list(dynamic d) => d is List ? d : const [];

  Future<AuthResult> register(String email, String password, String nickname) async =>
      AuthResult.fromJson(_map(await _req('POST', '/api/register',
          body: {'email': email, 'password': password, 'nickname': nickname})));

  Future<AuthResult> login(String email, String password) async =>
      AuthResult.fromJson(_map(await _req('POST', '/api/login', body: {'email': email, 'password': password})));

  Future<User> me() async => User.fromJson(_map(await _req('GET', '/api/me')));

  Future<User> searchUser(String email) async =>
      User.fromJson(_map(await _req('GET', '/api/users/search', query: {'email': email})));

  Future<int> openDirect(int peerId) async =>
      (_map(await _req('POST', '/api/conversations/direct', body: {'peer_id': peerId}))['conversation_id'] as num)
          .toInt();

  Future<List<Conversation>> conversations() async => _list(await _req('GET', '/api/conversations'))
      .whereType<Map<String, dynamic>>()
      .map(Conversation.fromJson)
      .toList();

  Future<List<Message>> messages(int cid, {int? after, int? before, int? changedSince, int limit = 50}) async {
    final q = <String, String>{};
    if (after != null && after > 0) q['after_seq'] = '$after';
    if (before != null && before > 0) q['before_seq'] = '$before';
    if (changedSince != null && changedSince > 0) q['changed_since'] = '$changedSince';
    q['limit'] = '$limit';
    return _list(await _req('GET', '/api/conversations/$cid/messages', query: q))
        .whereType<Map<String, dynamic>>()
        .map(Message.fromJson)
        .toList();
  }

  Future<Map<int, int>> reads(int cid) async {
    final m = _map(await _req('GET', '/api/conversations/$cid/reads'));
    return m.map((k, v) => MapEntry(int.tryParse(k) ?? 0, (v as num).toInt()));
  }

  // v0.2.0
  Future<ClientConfig> config() async => ClientConfig.fromJson(_map(await _req('GET', '/api/config')));

  Future<Conversation> conversation(int cid) async =>
      Conversation.fromJson(_map(await _req('GET', '/api/conversations/$cid')));

  Future<(int, Conversation?)> createGroup(String name, List<int> memberIds) async {
    final m = _map(await _req('POST', '/api/conversations/group', body: {'name': name, 'member_ids': memberIds}));
    final c = m['conversation'];
    return ((m['conversation_id'] as num).toInt(), c is Map<String, dynamic> ? Conversation.fromJson(c) : null);
  }

  Future<Conversation> updateGroup(int cid, {String? name, String? announcement}) async =>
      Conversation.fromJson(_map(await _req('PATCH', '/api/conversations/$cid', body: {
        'name': ?name,
        'announcement': ?announcement,
      })));

  Future<List<Member>> members(int cid) async => _list(await _req('GET', '/api/conversations/$cid/members'))
      .whereType<Map<String, dynamic>>()
      .map(Member.fromJson)
      .toList();

  Future<void> addMembers(int cid, List<int> userIds) =>
      _req('POST', '/api/conversations/$cid/members', body: {'user_ids': userIds});

  Future<void> removeMember(int cid, int uid) => _req('DELETE', '/api/conversations/$cid/members/$uid');

  Future<void> setRole(int cid, int uid, String role) =>
      _req('PUT', '/api/conversations/$cid/members/$uid/role', body: {'role': role});

  Future<void> leave(int cid) => _req('POST', '/api/conversations/$cid/leave');

  Future<List<int>> hidden(int cid, int minSeq) async =>
      _list(await _req('GET', '/api/conversations/$cid/hidden', query: {'min_seq': '$minSeq'}))
          .map((e) => (e as num).toInt())
          .toList();

  Future<PresignResult> presign({required String mime, required int size, required int durationMs}) async =>
      PresignResult.fromJson(_map(await _req('POST', '/api/uploads/presign',
          body: {'kind': 'voice', 'mime': mime, 'size': size, 'duration_ms': durationMs})));

  // v0.3.0
  Future<PresignResult> presignImage({required String mime, required int size, required int width, required int height}) async =>
      PresignResult.fromJson(_map(await _req('POST', '/api/uploads/presign',
          body: {'kind': 'image', 'mime': mime, 'size': size, 'width': width, 'height': height})));

  Future<List<Presence>> presence(List<int> ids) async {
    if (ids.isEmpty) return const [];
    return _list(await _req('GET', '/api/presence', query: {'ids': ids.join(',')}))
        .whereType<Map<String, dynamic>>()
        .map(Presence.fromJson)
        .toList();
  }

  Future<TranscriptResult> transcribe(int cid, int seq) async => TranscriptResult.fromJson(
      _map(await _req('POST', '/api/conversations/$cid/messages/$seq/transcribe', timeout: const Duration(seconds: 70))));

  Future<MediaInfo> media(int cid, int seq) async =>
      MediaInfo.fromJson(_map(await _req('GET', '/api/conversations/$cid/messages/$seq/media')));

  /// 直传到对象存储（预签名 URL，不带 Authorization）
  Future<void> upload(PresignResult pre, Uint8List bytes) async {
    final req = http.Request(pre.method.isEmpty ? 'PUT' : pre.method, Uri.parse(pre.url));
    req.headers.addAll(pre.headers);
    req.bodyBytes = bytes;
    final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 120)));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiError(res.statusCode, 'upload', '上传失败 (${res.statusCode})');
    }
  }

  /// 下载预签名 GET URL；返回 (状态码, 内容)
  Future<(int, Uint8List)> download(String url) async {
    final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
    return (res.statusCode, res.bodyBytes);
  }
}
