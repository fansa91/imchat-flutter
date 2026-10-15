import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as pathlib;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'image_cache.dart';
import 'image_prep.dart';
import 'models.dart';
import 'recorder.dart';
import 'settings.dart';
import 'socket.dart';
import 'util.dart';
import 'voice_cache.dart';

/// 一个会话已加载的消息
class Thread {
  /// 服务端已确认的消息，按 seq 升序
  List<Message> items = [];

  /// 本地待确认（发送中 / 失败）
  List<Message> pending = [];
  bool loaded = false;
  bool hasMore = true;
  bool loadingMore = false;

  /// 已应用的变更位置（撤回/回应），重连后用 changed_since 补拉
  int modSeq = 0;
}

/// 语音 / 图片本地状态：loading 下载中 / ready 本地有 / expired 服务器已过期且本地没有 / error
enum VoiceState { loading, ready, expired, error }

typedef MediaState = VoiceState;

class TypingInfo {
  final int uid;
  final int ts;
  const TypingInfo(this.uid, this.ts);
  bool get active => ts != 0;
}

const int _page = 50;

/// 转文字失败的提示文案
String transcribeError(Object e) {
  if (e is ApiError) {
    if (e.code == 'stt_limit' || e.status == 429) return '今日转文字次数已用完';
    if (e.code == 'stt_disabled' || e.status == 501) return '服务器未开启语音转文字';
    if (e.code == 'recalled' || e.status == 410) return '消息已撤回';
    if (e.code == 'stt_failed' || e.status == 502) return '转文字失败，请稍后再试';
    return e.message;
  }
  return '转文字失败';
}
const Duration _sendTimeout = Duration(seconds: 10);

/// 全局状态与业务逻辑（移植自 imweb/src/store.ts，协议保持一致）
class ChatStore extends ChangeNotifier {
  ChatStore(this.settings) : api = Api(server: settings.server, token: settings.token) {
    api.onUnauthorized = logout;
    socket = ChatSocket(server: () => settings.server, token: () => settings.token);
    socket.onStatus = (s) {
      conn = s;
      _notify();
    };
    socket.onOpen = _sync;
    socket.on('send_ack', (d, _) => _onAck(Message.fromJson(_m(d)['message'])));
    socket.on('message', (d, _) => _onMessage(Message.fromJson(_m(d)['message'])));
    socket.on('read', (d, _) {
      final m = _m(d);
      _onRead(_i(m['conversation_id']), _i(m['user_id']), _i(m['read_seq']));
    });
    socket.on('typing', (d, _) {
      final m = _m(d);
      _onTyping(_i(m['conversation_id']), _i(m['user_id']));
    });
    socket.on('recall', (d, _) => _onRecall(Message.fromJson(_m(d)['message'])));
    socket.on('reaction', (d, _) {
      final m = _m(d);
      _onReaction(
        _i(m['conversation_id']),
        _i(m['seq']),
        ((m['reactions'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(Reaction.fromJson).toList(),
        _i(m['mod_seq']),
      );
    });
    socket.on('deleted', (d, _) {
      final m = _m(d);
      _onDeleted(_i(m['conversation_id']), ((m['seqs'] as List?) ?? const []).map(_i).toList());
    });
    socket.on('presence', (d, _) => _onPresence(Presence.fromJson(_m(d))));
    socket.on('conversation_updated', (d, _) => refreshConversation(_i(_m(d)['conversation_id'])));
    socket.on('conversation_removed', (d, _) => _dropConversation(_i(_m(d)['conversation_id'])));
    socket.on('error', (d, id) {
      if (id != null && _timers.containsKey(id)) {
        _failPending(id);
      } else if (id != null) {
        showToast((_m(d)['message'] ?? '操作失败').toString());
      }
      debugPrint('server error: $d');
    });
  }

  static Map<String, dynamic> _m(dynamic d) => d is Map<String, dynamic> ? d : <String, dynamic>{};
  static int _i(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

  final Settings settings;
  final Api api;
  late final ChatSocket socket;
  VoiceCache? _cache;
  ImageFileCache? _imgCache;

  User? me;
  bool booting = true;
  ConnState conn = ConnState.offline;
  ClientConfig config = const ClientConfig();
  final Map<int, Conversation> convs = {};
  final Map<int, Thread> threads = {};

  /// 会话 -> 成员 -> 已读 seq
  final Map<int, Map<int, int>> reads = {};

  /// 会话 -> 最近在输入的人
  final Map<int, TypingInfo> typing = {};

  /// 已知用户（群成员名字/头像）
  final Map<int, User> users = {};

  /// 已加载的群成员
  final Map<int, List<Member>> members = {};

  /// voiceKey -> 状态
  final Map<String, VoiceState> voice = {};

  /// imageKey（会话:seq）-> 状态
  final Map<String, MediaState> images = {};

  /// 用户 -> 在线状态（presence_enabled 时）
  final Map<int, Presence> presence = {};

  /// 语音转文字：会话:seq -> 文本（内存，持久化在 Settings）
  final Map<String, String> transcripts = {};

  /// 正在转写的语音（会话:seq）
  final Set<String> transcribing = {};

  final _toasts = StreamController<String>.broadcast();
  Stream<String> get toasts => _toasts.stream;

  final Map<String, Timer> _timers = {};

  /// 本地语音文件：发送中的按 client_msg_id，已确认的按 voiceKey
  final Map<String, File> _localVoice = {};

  /// 本地图片文件：发送中的按 client_msg_id，已确认的按 imageKey
  final Map<String, File> _localImage = {};
  final List<(int, int, bool)> _downloadQueue = [];
  int _downloading = 0;

  /// 自己撤回的文本，用于“重新编辑”
  final Map<String, String> recalledDrafts = {};
  int? activeId;
  bool foreground = true;
  bool _disposed = false;

  final _uuid = const Uuid();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    socket.stop();
    for (final t in _timers.values) {
      t.cancel();
    }
    _toasts.close();
    super.dispose();
  }

  void showToast(String text) {
    if (!_toasts.isClosed) _toasts.add(text);
  }

  Thread thread(int id) => threads.putIfAbsent(id, Thread.new);

  void _addUsers(Iterable<User?> list) {
    for (final u in list) {
      if (u == null || u.id == 0) continue;
      final cur = users[u.id];
      if (cur == null || cur.nickname != u.nickname) users[u.id] = u;
    }
  }

  // ---------- 会话生命周期 ----------

  Future<void> boot() async {
    api.server = settings.server;
    api.token = settings.token;
    if (settings.token.isEmpty) {
      booting = false;
      _notify();
      return;
    }
    try {
      me = await api.me();
      _addUsers([me]);
      booting = false;
      _notify();
      await _afterLogin();
    } catch (e) {
      booting = false;
      if (e is ApiError && e.status == 401) await settings.setToken('');
      _notify();
    }
  }

  Future<void> _afterLogin() async {
    _cache = await VoiceCache.open(settings.server);
    _imgCache = await ImageFileCache.open(settings.server);
    socket.start();
    api.config().then((c) {
      config = c;
      _notify();
      refreshPresence();
    }).catchError((_) {});
    loadConversations().catchError((_) => <Conversation>[]);
  }

  Future<void> login(String email, String password, {bool register = false, String nickname = ''}) async {
    api.server = settings.server;
    api.token = '';
    final r = register ? await api.register(email, password, nickname) : await api.login(email, password);
    await settings.setToken(r.token);
    api.token = r.token;
    _reset();
    booting = false;
    me = r.user;
    _addUsers([r.user]);
    _notify();
    await _afterLogin();
  }

  void _reset() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _localVoice.clear();
    _localImage.clear();
    _downloadQueue.clear();
    me = null;
    conn = ConnState.offline;
    config = const ClientConfig();
    convs.clear();
    threads.clear();
    reads.clear();
    typing.clear();
    users.clear();
    members.clear();
    voice.clear();
    images.clear();
    presence.clear();
    transcripts.clear();
    transcribing.clear();
    recalledDrafts.clear();
    activeId = null;
  }

  Future<void> logout() async {
    socket.stop();
    await settings.setToken('');
    api.token = '';
    _reset();
    booting = false;
    _notify();
  }

  /// App 回到前台
  void onResume() {
    foreground = true;
    socket.kick();
    if (activeId != null) markRead(activeId!);
  }

  void onPause() {
    foreground = false;
  }

  List<Conversation> get sortedConversations {
    final list = convs.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  int get totalUnread => convs.values.fold(0, (s, c) => s + c.unread);

  Future<List<Conversation>> loadConversations() async {
    final list = await api.conversations();
    final next = <int, Conversation>{};
    for (final c in list) {
      final local = convs[c.id];
      // 请求期间通过 WebSocket 收到了更新的消息，以本地为准，避免被旧快照覆盖
      if (local != null && local.lastSeq > c.lastSeq) {
        next[c.id] = local.copyWith(
          peer: c.peer ?? local.peer,
          name: c.name,
          membersPreview: c.membersPreview,
          modSeq: max(local.modSeq, c.modSeq),
        );
      } else {
        next[c.id] = c;
      }
      _addUsers([c.peer, ...c.membersPreview]);
    }
    convs
      ..clear()
      ..addAll(next);
    _notify();
    return list;
  }

  Future<void> refreshConversation(int id) async {
    try {
      final c = await api.conversation(id);
      final local = convs[id];
      if (local != null) {
        final newer = local.lastSeq > c.lastSeq;
        convs[id] = c.copyWith(
          lastSeq: max(local.lastSeq, c.lastSeq),
          lastMessage: newer ? local.lastMessage : c.lastMessage,
          readSeq: max(local.readSeq, c.readSeq),
          unread: newer ? local.unread : c.unread,
          updatedAt: newer ? local.updatedAt : c.updatedAt,
        );
      } else {
        convs[id] = c;
      }
      _addUsers([c.peer, ...c.membersPreview]);
      _notify();
      if (members.containsKey(id)) loadMembers(id);
    } catch (e) {
      if (e is ApiError && e.status == 403) _dropConversation(id);
    }
  }

  void _dropConversation(int id) {
    convs.remove(id);
    threads.remove(id);
    if (activeId == id) activeId = null;
    _notify();
  }

  /// 连接（重连）后：刷新会话列表，补拉已打开会话的新消息和变更，补发未确认的消息
  Future<void> _sync() async {
    try {
      await loadConversations();
      refreshPresence();
      for (final id in threads.keys.toList()) {
        final t = threads[id];
        if (t == null || !t.loaded) continue;
        if (!convs.containsKey(id)) {
          _dropConversation(id);
          continue;
        }
        await _catchUp(id);
        await _catchUpChanges(id);
        await _syncHidden(id);
        if (activeId == id) _loadReads(id);
      }
      for (final t in threads.values) {
        for (final m in t.pending.toList()) {
          if (m.status == MsgStatus.sending) {
            if (m.msgType == msgVoice || m.msgType == msgImage) {
              _uploadAndSend(m);
            } else {
              _transmit(m);
            }
          }
        }
      }
      if (activeId != null) markRead(activeId!);
    } catch (e) {
      debugPrint('sync failed: $e');
    }
  }

  Future<void> _catchUp(int id) async {
    for (;;) {
      final t = threads[id];
      if (t == null) return;
      final after = t.items.isNotEmpty ? t.items.last.seq : 0;
      final msgs = await api.messages(id, after: after, limit: after > 0 ? 200 : _page);
      _mergeMessages(id, msgs);
      if (after == 0 || msgs.length < 200) break;
    }
  }

  /// 离线期间的撤回 / 表情回应变化
  Future<void> _catchUpChanges(int id) async {
    final conv = convs[id];
    for (var i = 0; i < 20; i++) {
      final t = threads[id];
      if (t == null || conv == null || conv.modSeq <= t.modSeq) return;
      // 服务端 changed_since=0 等价于“不带参数”（返回最新一页），所以没有基线时直接用最新一页覆盖已加载消息
      final msgs = await api.messages(id, changedSince: t.modSeq == 0 ? null : t.modSeq, limit: 200);
      if (t.modSeq == 0) {
        // 没有变更基线：最新一页本身就是最新状态
        _replaceMessages(id, msgs.where((m) => t.items.any((x) => x.seq == m.seq)).toList());
        t.modSeq = conv.modSeq;
        _notify();
        return;
      }
      if (msgs.isEmpty) {
        t.modSeq = conv.modSeq;
        return;
      }
      final loaded = t.items.map((m) => m.seq).toSet();
      _replaceMessages(id, msgs.where((m) => loaded.contains(m.seq)).toList());
      final maxMod = msgs.map((m) => m.modSeq).fold(0, max);
      t.modSeq = max(t.modSeq, maxMod);
      if (msgs.length < 200) return;
    }
  }

  /// 其他设备上删除的消息
  Future<void> _syncHidden(int id) async {
    final t = threads[id];
    if (t == null || t.items.isEmpty) return;
    final seqs = await api.hidden(id, t.items.first.seq);
    if (seqs.isNotEmpty) _onDeleted(id, seqs);
  }

  Future<void> openConversation(int id) async {
    activeId = id;
    final conv = convs[id];
    final t = thread(id);
    if (!t.loaded) {
      try {
        final modSeq = conv?.modSeq ?? 0;
        final msgs = await api.messages(id, limit: _page);
        t.loaded = true;
        t.hasMore = msgs.length == _page;
        t.modSeq = max(t.modSeq, modSeq);
        _mergeMessages(id, msgs);
        _notify();
      } catch (e) {
        showToast(e is ApiError ? e.message : '加载消息失败');
      }
    }
    if (conv?.isGroup == true) loadMembers(id);
    _loadReads(id);
    markRead(id);
  }

  void closeConversation() {
    activeId = null;
  }

  Future<List<Member>> loadMembers(int id) async {
    try {
      final list = await api.members(id);
      _addUsers(list.map((m) => m.user));
      members[id] = list;
      _notify();
      refreshPresence(list.map((m) => m.user.id).where((u) => !presence.containsKey(u)));
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadReads(int id) async {
    try {
      final r = await api.reads(id);
      final cur = reads.putIfAbsent(id, () => {});
      r.forEach((uid, seq) => cur[uid] = max(seq, cur[uid] ?? 0));
      _notify();
    } catch (_) {}
  }

  Future<void> loadMore(int id) async {
    final t = threads[id];
    if (t == null || !t.hasMore || t.loadingMore || t.items.isEmpty) return;
    t.loadingMore = true;
    _notify();
    try {
      final msgs = await api.messages(id, before: t.items.first.seq, limit: _page);
      _mergeMessages(id, msgs);
      t.hasMore = msgs.length == _page;
    } catch (_) {}
    t.loadingMore = false;
    _notify();
  }

  /// 引用跳转：一直往前翻直到加载到指定 seq（最多 20 页）
  Future<bool> ensureLoaded(int id, int seq) async {
    for (var i = 0; i < 20; i++) {
      final t = threads[id];
      if (t == null || t.items.isEmpty || t.items.first.seq <= seq || !t.hasMore) {
        return t?.items.any((m) => m.seq == seq) ?? false;
      }
      await loadMore(id);
    }
    return threads[id]?.items.any((m) => m.seq == seq) ?? false;
  }

  Future<int> startChatByEmail(String email) async {
    final user = await api.searchUser(email.trim().toLowerCase());
    _addUsers([user]);
    final cid = await api.openDirect(user.id);
    if (!convs.containsKey(cid)) {
      await loadConversations();
      if (!convs.containsKey(cid)) {
        // 新会话还没有消息时，本地先放一条占位
        convs[cid] = Conversation(id: cid, type: convDirect, updatedAt: DateTime.now(), peer: user);
        _notify();
      }
    }
    return cid;
  }

  Future<User> findUser(String email) async {
    final u = await api.searchUser(email.trim().toLowerCase());
    _addUsers([u]);
    return u;
  }

  Future<int> createGroup(String name, List<int> memberIds) async {
    final (cid, conv) = await api.createGroup(name, memberIds);
    if (conv != null) {
      convs[cid] = conv;
      _addUsers(conv.membersPreview);
      _notify();
    } else {
      await loadConversations();
    }
    return cid;
  }

  Future<void> renameGroup(int id, String name) async {
    final c = await api.updateGroup(id, name: name);
    final cur = convs[id];
    if (cur != null) convs[id] = cur.copyWith(name: c.name);
    _notify();
  }

  Future<void> setAnnouncement(int id, String announcement) async {
    final c = await api.updateGroup(id, announcement: announcement);
    final cur = convs[id];
    if (cur != null) {
      convs[id] = cur.copyWith(
        announcement: c.announcement,
        announcementAt: c.announcementAt,
        announcementBy: c.announcementBy,
      );
    }
    _notify();
  }

  Future<void> addMembers(int id, List<int> uids) async {
    await api.addMembers(id, uids);
    await loadMembers(id);
  }

  Future<void> removeMember(int id, int uid) async {
    await api.removeMember(id, uid);
    await loadMembers(id);
  }

  Future<void> setRole(int id, int uid, String role) async {
    await api.setRole(id, uid, role);
    await loadMembers(id);
  }

  Future<void> leaveGroup(int id) async {
    await api.leave(id);
    _dropConversation(id);
  }

  // ---------- 消息 ----------

  void _mergeMessages(int id, List<Message> msgs) {
    if (msgs.isEmpty) return;
    final t = thread(id);
    final bySeq = <int, Message>{for (final m in t.items) m.seq: m};
    for (final m in msgs) {
      bySeq[m.seq] = m.copyWith(status: MsgStatus.sent);
    }
    t.items = bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    final ids = msgs.where((m) => m.senderId == me?.id).map((m) => m.clientMsgId).toSet();
    t.pending = t.pending.where((p) => !ids.contains(p.clientMsgId)).toList();

    final last = msgs.reduce((a, b) => b.seq > a.seq ? b : a);
    final c = convs[id];
    if (c != null && last.seq >= c.lastSeq) {
      convs[id] = c.copyWith(
        lastSeq: last.seq,
        lastMessage: last,
        lastSenderName: users[last.senderId]?.nickname ?? c.lastSenderName,
        updatedAt: last.createdAt,
        unread: max(0, last.seq - c.readSeq),
      );
    }
    for (final m in msgs) {
      if (m.msgType == msgVoice && !m.recalled) _ensureVoice(m);
      if (m.msgType == msgImage && !m.recalled) _ensureImage(m);
    }
    _notify();
  }

  /// 用新版本替换已加载的消息（撤回、回应变化）
  void _replaceMessages(int id, List<Message> msgs) {
    if (msgs.isEmpty) return;
    final by = {for (final m in msgs) m.seq: m};
    final t = thread(id);
    t.items = t.items.map((m) => by.containsKey(m.seq) ? by[m.seq]!.copyWith(status: MsgStatus.sent) : m).toList();
    final c = convs[id];
    if (c?.lastMessage != null && by.containsKey(c!.lastMessage!.seq)) {
      convs[id] = c.copyWith(lastMessage: by[c.lastMessage!.seq]);
    }
    for (final m in msgs) {
      if (m.recalled) _forgetMedia(id, m.seq);
    }
    _notify();
  }

  void send(int id, String text, {int? replyToSeq}) {
    final content = text.trim();
    if (content.isEmpty || me == null) return;
    _transmit(_addPending(id, msgText, content, replyToSeq));
  }

  Message _addPending(int id, int msgType, String content, int? replyToSeq) {
    final m = Message(
      conversationId: id,
      seq: 0,
      senderId: me!.id,
      clientMsgId: _uuid.v4(),
      msgType: msgType,
      content: content,
      createdAt: DateTime.now(),
      replyToSeq: (replyToSeq == null || replyToSeq == 0) ? null : replyToSeq,
      replyTo: (replyToSeq == null || replyToSeq == 0) ? null : _replyPreviewFor(id, replyToSeq),
      status: MsgStatus.sending,
    );
    thread(id).pending.add(m);
    _notify();
    return m;
  }

  ReplyPreview? _replyPreviewFor(int id, int seq) {
    final items = threads[id]?.items ?? const <Message>[];
    final o = items.where((m) => m.seq == seq).firstOrNull;
    if (o == null) return null;
    final sp = shortPreview(o);
    final preview = sp.length > 80 ? sp.substring(0, 80) : sp;
    return ReplyPreview(seq: seq, senderId: o.senderId, msgType: o.msgType, preview: preview, recalled: o.recalled);
  }

  /// 语音：先占位显示，上传到对象存储（预签名 PUT）后再通过 WebSocket 发送
  Future<void> sendVoice(int id, Recording rec, {int? replyToSeq}) async {
    if (me == null) return;
    final local = VoiceContent(
      key: '',
      mime: rec.mime,
      durationMs: rec.durationMs,
      size: rec.size,
      waveform: rec.waveform,
    );
    final m = _addPending(id, msgVoice, local.encode(), replyToSeq);
    _localVoice[m.clientMsgId] = rec.file;
    await _uploadAndSend(m);
  }

  void _updatePending(String clientId, Message Function(Message) fn) {
    for (final t in threads.values) {
      final i = t.pending.indexWhere((p) => p.clientMsgId == clientId);
      if (i >= 0) t.pending[i] = fn(t.pending[i]);
    }
    _notify();
  }

  /// 图片：压缩后先占位显示（本地文件），上传后再通过 WebSocket 发送
  Future<void> sendImage(int id, Uint8List raw, {int? replyToSeq}) async {
    if (me == null) return;
    PreparedImage img;
    try {
      img = await prepareImage(raw);
    } catch (e) {
      showToast(e is ImagePrepException ? e.message : '无法处理这张图片');
      return;
    }
    final maxBytes = config.imageMaxBytes ?? 10485760;
    if (img.bytes.length > maxBytes) {
      showToast('图片不能超过 ${(maxBytes / 1048576).toStringAsFixed(maxBytes % 1048576 == 0 ? 0 : 1)} MB');
      return;
    }
    File file;
    try {
      final dir = await getTemporaryDirectory();
      file = File(pathlib.join(dir.path, 'imchat_${_uuid.v4()}.${ImageFileCache.extFor(img.mime)}'));
      await file.writeAsBytes(img.bytes, flush: true);
    } catch (e) {
      showToast('无法保存临时图片');
      return;
    }
    final local = ImageContent(key: '', mime: img.mime, size: img.bytes.length, width: img.width, height: img.height);
    final m = _addPending(id, msgImage, local.encode(), replyToSeq);
    _localImage[m.clientMsgId] = file;
    await _uploadAndSend(m);
  }

  Future<void> _uploadAndSend(Message m) async {
    if (m.msgType == msgImage) return _uploadImageAndSend(m);
    final file = _localVoice[m.clientMsgId];
    final vc = VoiceContent.of(m);
    if (vc == null) return _failPending(m.clientMsgId);
    var cur = m;
    if (vc.key.isEmpty) {
      if (file == null || !await file.exists()) return _failPending(m.clientMsgId);
      try {
        final bytes = await file.readAsBytes();
        final pre = await api.presign(mime: vc.mime, size: bytes.length, durationMs: vc.durationMs);
        await api.upload(pre, bytes);
        final content = vc.withKey(pre.key).encode();
        cur = m.copyWith(content: content);
        _updatePending(m.clientMsgId, (p) => p.copyWith(content: content));
      } catch (e) {
        showToast(e is ApiError ? e.message : '语音上传失败');
        return _failPending(m.clientMsgId);
      }
    }
    _transmit(cur);
  }

  Future<void> _uploadImageAndSend(Message m) async {
    final file = _localImage[m.clientMsgId];
    final ic = ImageContent.of(m);
    if (ic == null) return _failPending(m.clientMsgId);
    var cur = m;
    if (ic.key.isEmpty) {
      if (file == null || !await file.exists()) return _failPending(m.clientMsgId);
      try {
        final bytes = await file.readAsBytes();
        final pre = await api.presignImage(mime: ic.mime, size: bytes.length, width: ic.width, height: ic.height);
        await api.upload(pre, bytes);
        final content = ic.withKey(pre.key).encode();
        cur = m.copyWith(content: content);
        _updatePending(m.clientMsgId, (p) => p.copyWith(content: content));
      } catch (e) {
        showToast(e is ApiError ? e.message : '图片上传失败');
        return _failPending(m.clientMsgId);
      }
    }
    _transmit(cur);
  }

  void retry(Message m) {
    _updatePending(m.clientMsgId, (p) => p.copyWith(status: MsgStatus.sending));
    final cur = threads[m.conversationId]?.pending.where((p) => p.clientMsgId == m.clientMsgId).firstOrNull ?? m;
    if (cur.msgType == msgVoice || cur.msgType == msgImage) {
      _uploadAndSend(cur);
    } else {
      _transmit(cur);
    }
  }

  /// 发出（或重发同一个 client_msg_id，服务端保证幂等）
  void _transmit(Message m) {
    _timers.remove(m.clientMsgId)?.cancel();
    if (m.msgType == msgVoice && (VoiceContent.of(m)?.key ?? '').isEmpty) return; // 还没上传完
    if (m.msgType == msgImage && (ImageContent.of(m)?.key ?? '').isEmpty) return;
    final ok = socket.send(
      'send',
      {
        'client_msg_id': m.clientMsgId,
        'conversation_id': m.conversationId,
        'msg_type': m.msgType,
        'content': m.content,
        'reply_to_seq': m.replyToSeq ?? 0,
      },
      m.clientMsgId,
    );
    if (!ok) return; // 离线：保持“发送中”，连上后 sync 会补发
    _timers[m.clientMsgId] = Timer(_sendTimeout, () => _failPending(m.clientMsgId));
  }

  void _failPending(String clientId) {
    _timers.remove(clientId)?.cancel();
    _updatePending(clientId, (p) => p.copyWith(status: MsgStatus.failed));
  }

  /// 删除本地发送失败的消息
  void discardPending(Message m) {
    _timers.remove(m.clientMsgId)?.cancel();
    final f = _localVoice.remove(m.clientMsgId);
    if (f != null) f.delete().catchError((_) => f);
    final fi = _localImage.remove(m.clientMsgId);
    if (fi != null) fi.delete().catchError((_) => fi);
    final t = threads[m.conversationId];
    if (t != null) t.pending = t.pending.where((p) => p.clientMsgId != m.clientMsgId).toList();
    _notify();
  }

  Future<void> _onAck(Message m) async {
    _timers.remove(m.clientMsgId)?.cancel();
    // 自己发的语音：本地录音直接存入缓存，无需再下载
    final f = _localVoice.remove(m.clientMsgId);
    if (f != null && m.msgType == msgVoice && _cache != null) {
      final k = VoiceCache.key(m.conversationId, m.seq);
      voice[k] = VoiceState.ready;
      _localVoice[k] = f;
      try {
        final mime = VoiceContent.of(m)?.mime ?? 'audio/mp4';
        _localVoice[k] = await _cache!.adopt(m.conversationId, m.seq, mime, f);
      } catch (e) {
        debugPrint('save voice: $e');
      }
    }
    // 自己发的图片：压缩后的本地文件直接存入缓存
    // 待发送条目在确认前仍在显示，先移入缓存再移除临时引用，避免占位闪烁
    final fi = _localImage[m.clientMsgId];
    if (fi != null && m.msgType == msgImage && _imgCache != null) {
      final k = ImageFileCache.key(m.conversationId, m.seq);
      try {
        final mime = ImageContent.of(m)?.mime ?? 'image/jpeg';
        _localImage[k] = await _imgCache!.adopt(m.conversationId, m.seq, mime, fi);
        images[k] = MediaState.ready;
      } catch (e) {
        debugPrint('save image: $e');
      }
    }
    _localImage.remove(m.clientMsgId);
    _ingest(m, true);
  }

  void _onMessage(Message m) {
    final mine = m.senderId == me?.id;
    if (m.msgType == msgSystem && isMyExit(m, me?.id)) {
      _dropConversation(m.conversationId); // 自己退群 / 被移出：不再请求该会话
      return;
    }
    _ingest(m, mine);
    if (m.msgType == msgSystem && convs.containsKey(m.conversationId)) refreshConversation(m.conversationId);
    if (!mine) {
      final t = typing[m.conversationId];
      if (t != null && t.uid == m.senderId) typing[m.conversationId] = const TypingInfo(0, 0);
      if (activeId == m.conversationId && foreground) markRead(m.conversationId);
      _notify();
    }
  }

  void _ingest(Message m, bool mine) {
    final id = m.conversationId;
    if (!convs.containsKey(id)) {
      // 别人新发起的会话 / 刚被拉进群：先拉会话列表，再重新处理这条消息
      loadConversations().then((_) {
        if (convs.containsKey(id)) _ingest(m, mine);
      }).catchError((_) {});
      return;
    }
    final t = threads[id];
    if (t != null && t.loaded) {
      final lastSeq = t.items.isNotEmpty ? t.items.last.seq : 0;
      if (m.seq > lastSeq + 1) {
        _catchUp(id).catchError((_) {}); // 中间有缺口（或有自己删除的消息），补拉
        return;
      }
      _mergeMessages(id, [m]);
    } else {
      final c = convs[id]!;
      if (m.seq > c.lastSeq) {
        convs[id] = c.copyWith(
          lastSeq: m.seq,
          lastMessage: m,
          lastSenderName: users[m.senderId]?.nickname ?? c.lastSenderName,
          updatedAt: m.createdAt,
          unread: mine ? c.unread : max(0, m.seq - c.readSeq),
          readSeq: mine ? m.seq : c.readSeq,
        );
      }
      if (m.msgType == msgVoice) _ensureVoice(m); // 收到即下载，保证过期后仍能播放
      if (m.msgType == msgImage && !m.recalled) _ensureImage(m);
    }
    if (mine) {
      final c = convs[id];
      if (c != null && c.readSeq < m.seq) convs[id] = c.copyWith(readSeq: m.seq, unread: 0);
    }
    _notify();
  }

  void markRead(int id) {
    final c = convs[id];
    if (c == null || c.readSeq >= c.lastSeq) return;
    convs[id] = c.copyWith(readSeq: c.lastSeq, unread: 0);
    socket.send('read', {'conversation_id': id, 'seq': c.lastSeq});
    _notify();
  }

  void _onRead(int cid, int uid, int seq) {
    final cur = reads.putIfAbsent(cid, () => {});
    cur[uid] = max(seq, cur[uid] ?? 0);
    if (uid == me?.id) {
      final c = convs[cid];
      if (c != null && seq > c.readSeq) convs[cid] = c.copyWith(readSeq: seq, unread: max(0, c.lastSeq - seq));
    }
    _notify();
  }

  int _lastTypingSent = 0;
  void sendTyping(int id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTypingSent < 2500) return;
    _lastTypingSent = now;
    socket.send('typing', {'conversation_id': id});
  }

  void _onTyping(int cid, int uid) {
    final ts = DateTime.now().microsecondsSinceEpoch;
    typing[cid] = TypingInfo(uid, ts);
    _notify();
    Timer(const Duration(seconds: 4), () {
      if (typing[cid]?.ts == ts) {
        typing[cid] = const TypingInfo(0, 0);
        _notify();
      }
    });
  }

  // ---------- 撤回 / 表情回应 / 删除 ----------

  bool canRecall(Message m) =>
      m.senderId == me?.id &&
      m.seq > 0 &&
      !m.recalled &&
      m.msgType != msgSystem &&
      DateTime.now().difference(m.createdAt).inMilliseconds < config.recallSeconds * 1000 - 1500;

  void recall(Message m) {
    if (m.msgType == msgText) recalledDrafts['${m.conversationId}:${m.seq}'] = m.content;
    if (!socket.send('recall', {'conversation_id': m.conversationId, 'seq': m.seq}, _uuid.v4())) {
      showToast('网络未连接');
    }
  }

  void _onRecall(Message m) {
    final id = m.conversationId;
    final t = threads[id];
    if (t != null && t.loaded && t.items.any((x) => x.seq == m.seq)) {
      _replaceMessages(id, [m]);
    } else {
      final c = convs[id];
      if (c?.lastMessage?.seq == m.seq) convs[id] = c!.copyWith(lastMessage: m);
      _forgetMedia(id, m.seq);
    }
    // 引用了这条消息的回复也要更新预览
    if (t != null && t.loaded) {
      t.items = t.items
          .map((x) => x.replyTo?.seq == m.seq ? x.copyWith(replyTo: x.replyTo!.copyWith(recalled: true, preview: '')) : x)
          .toList();
      if (m.modSeq > 0) t.modSeq = max(t.modSeq, m.modSeq);
    }
    final c = convs[id];
    if (c != null) convs[id] = c.copyWith(modSeq: max(c.modSeq, m.modSeq));
    _notify();
  }

  void react(Message m, String emoji) {
    if (!socket.send('react', {'conversation_id': m.conversationId, 'seq': m.seq, 'emoji': emoji}, _uuid.v4())) {
      showToast('网络未连接');
    }
  }

  void _onReaction(int cid, int seq, List<Reaction> list, int modSeq) {
    final t = threads[cid];
    if (t != null && t.loaded) {
      t.items = t.items.map((m) => m.seq == seq ? m.copyWith(reactions: list) : m).toList();
      t.modSeq = max(t.modSeq, modSeq);
    }
    final c = convs[cid];
    if (c != null) convs[cid] = c.copyWith(modSeq: max(c.modSeq, modSeq));
    _notify();
  }

  /// 仅自己删除（同步到自己的其他设备，对方不受影响）
  void deleteForMe(Message m) {
    if (m.seq == 0) return discardPending(m);
    if (!socket.send('delete', {
      'conversation_id': m.conversationId,
      'seqs': [m.seq],
    }, _uuid.v4())) {
      showToast('网络未连接');
    }
  }

  void _onDeleted(int cid, List<int> seqs) {
    final set = seqs.toSet();
    final t = threads[cid];
    if (t != null) t.items = t.items.where((m) => !set.contains(m.seq)).toList();
    final c = convs[cid];
    if (c?.lastMessage != null && set.contains(c!.lastMessage!.seq)) {
      final items = threads[cid]?.items ?? const <Message>[];
      if (items.isNotEmpty) {
        convs[cid] = c.copyWith(lastMessage: items.last);
      } else {
        refreshConversation(cid);
      }
    }
    for (final s in seqs) {
      _forgetMedia(cid, s);
    }
    _notify();
  }

  // ---------- 语音本地缓存 ----------

  String voiceKeyOf(Message m) => VoiceCache.key(m.conversationId, m.seq);

  /// 确保语音在本地：缓存目录有就标记 ready，否则排队下载
  Future<void> _ensureVoice(Message m) async {
    final k = voiceKeyOf(m);
    if (voice[k] == VoiceState.ready || voice[k] == VoiceState.loading) return;
    voice[k] = VoiceState.loading;
    final f = await _cache?.find(m.conversationId, m.seq);
    if (f != null) {
      voice[k] = VoiceState.ready;
      _localVoice[k] = f;
      _notify();
      return;
    }
    _downloadQueue.add((m.conversationId, m.seq, false));
    _notify();
    _pump();
  }

  void _pump() {
    while (_downloading < 3 && _downloadQueue.isNotEmpty) {
      final (cid, seq, isImage) = _downloadQueue.removeAt(0);
      _downloading++;
      (isImage ? _downloadImage(cid, seq) : _download(cid, seq)).whenComplete(() {
        _downloading--;
        _pump();
      });
    }
  }

  Future<void> _download(int cid, int seq) async {
    final k = VoiceCache.key(cid, seq);
    var state = VoiceState.error;
    try {
      final info = await api.media(cid, seq);
      final (status, bytes) = await api.download(info.url);
      if (status == 404 || status == 403) {
        state = VoiceState.expired;
      } else if (status < 200 || status >= 300) {
        throw Exception('HTTP $status');
      } else if (_cache != null) {
        _localVoice[k] = await _cache!.put(cid, seq, info.mime, bytes);
        state = VoiceState.ready;
      }
    } catch (e) {
      if (e is ApiError && (e.status == 410 || e.status == 404)) {
        state = VoiceState.expired;
      } else {
        debugPrint('voice download failed: $e');
      }
    }
    // 下载期间被撤回 / 删除：不要复活
    if (voice[k] == null) {
      await _cache?.delete(cid, seq);
      _localVoice.remove(k);
      return;
    }
    voice[k] = state;
    _notify();
  }

  void retryVoice(Message m) {
    voice.remove(voiceKeyOf(m));
    _ensureVoice(m);
  }

  /// 播放用的本地文件：内存 → 缓存目录；都没有返回 null
  Future<File?> voiceFile(Message m) async {
    final k = m.seq > 0 ? voiceKeyOf(m) : m.clientMsgId;
    final f = _localVoice[k];
    if (f != null && await f.exists()) return f;
    if (m.seq > 0) {
      final c = await _cache?.find(m.conversationId, m.seq);
      if (c != null) _localVoice[k] = c;
      return c;
    }
    return null;
  }

  /// 撤回 / 删除：清理语音、图片、转写结果的本地副本
  void _forgetMedia(int cid, int seq) {
    final k = VoiceCache.key(cid, seq);
    _localVoice.remove(k);
    voice.remove(k);
    _cache?.delete(cid, seq);
    final ik = ImageFileCache.key(cid, seq);
    _localImage.remove(ik);
    images.remove(ik);
    _imgCache?.delete(cid, seq);
    if (transcripts.remove(k) != null || settings.transcript(cid, seq) != null) {
      settings.removeTranscript(cid, seq);
    }
    transcribing.remove(k);
  }

  // ---------- 图片本地缓存 ----------

  String imageKeyOf(Message m) => ImageFileCache.key(m.conversationId, m.seq);

  Future<void> _ensureImage(Message m) async {
    final k = imageKeyOf(m);
    if (images[k] == MediaState.ready || images[k] == MediaState.loading) return;
    images[k] = MediaState.loading;
    final f = await _imgCache?.find(m.conversationId, m.seq);
    if (f != null) {
      images[k] = MediaState.ready;
      _localImage[k] = f;
      _notify();
      return;
    }
    _downloadQueue.add((m.conversationId, m.seq, true));
    _notify();
    _pump();
  }

  Future<void> _downloadImage(int cid, int seq) async {
    final k = ImageFileCache.key(cid, seq);
    var state = MediaState.error;
    try {
      final info = await api.media(cid, seq);
      final (status, bytes) = await api.download(info.url);
      if (status == 404 || status == 403) {
        state = MediaState.expired;
      } else if (status < 200 || status >= 300) {
        throw Exception('HTTP $status');
      } else if (_imgCache != null) {
        _localImage[k] = await _imgCache!.put(cid, seq, info.mime, bytes);
        state = MediaState.ready;
      }
    } catch (e) {
      if (e is ApiError && (e.status == 410 || e.status == 404)) {
        state = MediaState.expired;
      } else {
        debugPrint('image download failed: $e');
      }
    }
    if (images[k] == null) {
      await _imgCache?.delete(cid, seq);
      _localImage.remove(k);
      return;
    }
    images[k] = state;
    _notify();
  }

  /// 气泡出现时调用：已确认的图片确保在本地
  void ensureImage(Message m) {
    if (m.seq == 0 || m.msgType != msgImage || m.recalled) return;
    if (images.containsKey(imageKeyOf(m))) return;
    Future.microtask(() => _ensureImage(m));
  }

  void retryImage(Message m) {
    images.remove(imageKeyOf(m));
    _ensureImage(m);
  }

  MediaState? imageState(Message m) => m.seq == 0 ? MediaState.ready : images[imageKeyOf(m)];

  /// 显示用的本地文件：发送中的用压缩后的临时文件，已确认的用缓存
  File? imageFileSync(Message m) => _localImage[m.seq > 0 ? imageKeyOf(m) : m.clientMsgId];

  Future<File?> imageFile(Message m) async {
    final k = m.seq > 0 ? imageKeyOf(m) : m.clientMsgId;
    final f = _localImage[k];
    if (f != null && await f.exists()) return f;
    if (m.seq > 0) {
      final c = await _imgCache?.find(m.conversationId, m.seq);
      if (c != null) _localImage[k] = c;
      return c;
    }
    return null;
  }

  // ---------- 在线状态 ----------

  /// 批量拉取在线状态；不传 ids 时取所有会话的已知成员
  Future<void> refreshPresence([Iterable<int>? ids]) async {
    if (!config.presenceEnabled || me == null) return;
    final all = <int>{};
    if (ids != null) {
      all.addAll(ids);
    } else {
      for (final c in convs.values) {
        if (c.peer != null) all.add(c.peer!.id);
        all.addAll(c.membersPreview.map((u) => u.id));
      }
      for (final list in members.values) {
        all.addAll(list.map((m) => m.user.id));
      }
    }
    all.removeWhere((u) => u == 0 || u == me?.id);
    final list = all.toList();
    for (var i = 0; i < list.length; i += 200) {
      try {
        final res = await api.presence(list.sublist(i, min(i + 200, list.length)));
        for (final p in res) {
          presence[p.userId] = p;
        }
      } catch (e) {
        debugPrint('presence failed: $e');
        return;
      }
    }
    if (list.isNotEmpty) _notify();
  }

  void _onPresence(Presence p) {
    if (p.userId == 0) return;
    presence[p.userId] = p;
    _notify();
  }

  bool isOnline(int uid) => config.presenceEnabled && (uid == me?.id || (presence[uid]?.online ?? false));

  /// 群聊在线人数（含自己）；成员未加载时返回 null
  int? onlineCount(int cid) {
    final list = members[cid];
    if (list == null) return null;
    return list.where((m) => isOnline(m.user.id)).length;
  }

  // ---------- 语音转文字 ----------

  String? transcriptOf(Message m) {
    if (m.seq == 0) return null;
    final k = VoiceCache.key(m.conversationId, m.seq);
    final t = transcripts[k];
    if (t != null) return t;
    final saved = settings.transcript(m.conversationId, m.seq);
    if (saved != null) transcripts[k] = saved;
    return saved;
  }

  bool isTranscribing(Message m) => transcribing.contains(VoiceCache.key(m.conversationId, m.seq));

  bool canTranscribe(Message m) =>
      config.sttEnabled && m.msgType == msgVoice && m.seq > 0 && !m.recalled && transcriptOf(m) == null && !isTranscribing(m);

  Future<void> transcribe(Message m) async {
    if (m.seq == 0 || m.msgType != msgVoice) return;
    final k = VoiceCache.key(m.conversationId, m.seq);
    if (transcribing.contains(k)) return;
    transcribing.add(k);
    _notify();
    try {
      final r = await api.transcribe(m.conversationId, m.seq);
      if (!transcribing.contains(k)) return; // 期间被撤回 / 删除
      final text = r.text.trim().isEmpty ? '（未识别到内容）' : r.text.trim();
      transcripts[k] = text;
      await settings.saveTranscript(m.conversationId, m.seq, text);
    } catch (e) {
      showToast(transcribeError(e));
    } finally {
      transcribing.remove(k);
      _notify();
    }
  }

  // ---------- 视图辅助 ----------

  String nameOf(int uid) => uid == me?.id ? '你' : (users[uid] != null ? displayName(users[uid]) : '群成员');
}
