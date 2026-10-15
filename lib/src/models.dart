// 与 imserver 的 JSON 结构一一对应（见 imserver/internal/store、internal/ws/protocol.go）。
import 'dart:convert';

const int msgText = 1;
const int msgImage = 2;
const int msgVoice = 3;
const int msgSystem = 10;

const int convDirect = 1;
const int convGroup = 2;

/// 群角色：0 成员 1 管理员 2 群主
const int roleMember = 0;
const int roleAdmin = 1;
const int roleOwner = 2;

int _int(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

int? _intOrNull(dynamic v) => v == null ? null : _int(v);

String _str(dynamic v) => v == null ? '' : v.toString();

bool _bool(dynamic v) => v == true;

DateTime _date(dynamic v) {
  if (v is String && v.isNotEmpty) {
    return DateTime.tryParse(v)?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

DateTime? _dateOrNull(dynamic v) => (v is String && v.isNotEmpty) ? DateTime.tryParse(v)?.toLocal() : null;

String _iso(DateTime d) => d.toUtc().toIso8601String();

class User {
  final int id;
  final String email;
  final String nickname;
  final String avatarUrl;
  final DateTime? createdAt;

  const User({required this.id, this.email = '', this.nickname = '', this.avatarUrl = '', this.createdAt});

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: _int(j['id']),
        email: _str(j['email']),
        nickname: _str(j['nickname']),
        avatarUrl: _str(j['avatar_url']),
        createdAt: _dateOrNull(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'nickname': nickname,
        'avatar_url': avatarUrl,
        if (createdAt != null) 'created_at': _iso(createdAt!),
      };
}

class Reaction {
  final String emoji;
  final int count;
  final List<int> userIds;

  const Reaction({required this.emoji, required this.count, required this.userIds});

  factory Reaction.fromJson(Map<String, dynamic> j) => Reaction(
        emoji: _str(j['emoji']),
        count: _int(j['count']),
        userIds: ((j['user_ids'] as List?) ?? const []).map(_int).toList(),
      );

  Map<String, dynamic> toJson() => {'emoji': emoji, 'count': count, 'user_ids': userIds};
}

class ReplyPreview {
  final int seq;
  final int senderId;
  final int msgType;
  final String preview;
  final bool recalled;
  final bool missing;

  const ReplyPreview({
    required this.seq,
    required this.senderId,
    required this.msgType,
    this.preview = '',
    this.recalled = false,
    this.missing = false,
  });

  factory ReplyPreview.fromJson(Map<String, dynamic> j) => ReplyPreview(
        seq: _int(j['seq']),
        senderId: _int(j['sender_id']),
        msgType: _int(j['msg_type']),
        preview: _str(j['preview']),
        recalled: _bool(j['recalled']),
        missing: _bool(j['missing']),
      );

  ReplyPreview copyWith({String? preview, bool? recalled}) => ReplyPreview(
        seq: seq,
        senderId: senderId,
        msgType: msgType,
        preview: preview ?? this.preview,
        recalled: recalled ?? this.recalled,
        missing: missing,
      );

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'sender_id': senderId,
        'msg_type': msgType,
        'preview': preview,
        'recalled': recalled,
        if (missing) 'missing': true,
      };
}

enum MsgStatus { sending, failed, sent }

class Message {
  final int conversationId;

  /// 未确认的本地消息为 0
  final int seq;
  final int senderId;
  final String clientMsgId;
  final int msgType;
  final String content;
  final DateTime createdAt;
  final int? replyToSeq;
  final ReplyPreview? replyTo;
  final bool recalled;
  final DateTime? recalledAt;
  final int modSeq;
  final List<Reaction> reactions;
  final MsgStatus status;

  const Message({
    required this.conversationId,
    required this.seq,
    required this.senderId,
    required this.clientMsgId,
    required this.msgType,
    required this.content,
    required this.createdAt,
    this.replyToSeq,
    this.replyTo,
    this.recalled = false,
    this.recalledAt,
    this.modSeq = 0,
    this.reactions = const [],
    this.status = MsgStatus.sent,
  });

  factory Message.fromJson(Map<String, dynamic> j) {
    final rt = j['reply_to'];
    final rs = _intOrNull(j['reply_to_seq']);
    return Message(
      conversationId: _int(j['conversation_id']),
      seq: _int(j['seq']),
      senderId: _int(j['sender_id']),
      clientMsgId: _str(j['client_msg_id']),
      msgType: _int(j['msg_type']),
      content: _str(j['content']),
      createdAt: _date(j['created_at']),
      replyToSeq: (rs == null || rs == 0) ? null : rs,
      replyTo: rt is Map<String, dynamic> ? ReplyPreview.fromJson(rt) : null,
      recalled: _bool(j['recalled']),
      recalledAt: _dateOrNull(j['recalled_at']),
      modSeq: _int(j['mod_seq']),
      reactions: ((j['reactions'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Reaction.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'conversation_id': conversationId,
        'seq': seq,
        'sender_id': senderId,
        'client_msg_id': clientMsgId,
        'msg_type': msgType,
        'content': content,
        'created_at': _iso(createdAt),
        if (replyToSeq != null) 'reply_to_seq': replyToSeq,
        if (replyTo != null) 'reply_to': replyTo!.toJson(),
        if (recalled) 'recalled': true,
        if (recalledAt != null) 'recalled_at': _iso(recalledAt!),
        if (modSeq != 0) 'mod_seq': modSeq,
        if (reactions.isNotEmpty) 'reactions': reactions.map((r) => r.toJson()).toList(),
      };

  bool get isSystem => msgType == msgSystem;

  Message copyWith({
    String? content,
    MsgStatus? status,
    List<Reaction>? reactions,
    ReplyPreview? replyTo,
  }) =>
      Message(
        conversationId: conversationId,
        seq: seq,
        senderId: senderId,
        clientMsgId: clientMsgId,
        msgType: msgType,
        content: content ?? this.content,
        createdAt: createdAt,
        replyToSeq: replyToSeq,
        replyTo: replyTo ?? this.replyTo,
        recalled: recalled,
        recalledAt: recalledAt,
        modSeq: modSeq,
        reactions: reactions ?? this.reactions,
        status: status ?? this.status,
      );
}

/// 语音消息 content（JSON 字符串）
class VoiceContent {
  final String key;
  final String mime;
  final int durationMs;
  final int size;
  final List<int> waveform;

  const VoiceContent({
    required this.key,
    required this.mime,
    required this.durationMs,
    required this.size,
    this.waveform = const [],
  });

  factory VoiceContent.fromJson(Map<String, dynamic> j) => VoiceContent(
        key: _str(j['key']),
        mime: _str(j['mime']),
        durationMs: _int(j['duration_ms']),
        size: _int(j['size']),
        waveform: ((j['waveform'] as List?) ?? const []).map(_int).toList(),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'mime': mime,
        'duration_ms': durationMs,
        'size': size,
        if (waveform.isNotEmpty) 'waveform': waveform,
      };

  String encode() => jsonEncode(toJson());

  VoiceContent withKey(String k) =>
      VoiceContent(key: k, mime: mime, durationMs: durationMs, size: size, waveform: waveform);

  /// 解析消息里的语音内容；非语音或已撤回返回 null
  static VoiceContent? of(Message m) {
    if (m.msgType != msgVoice || m.recalled) return null;
    try {
      final d = jsonDecode(m.content);
      return d is Map<String, dynamic> ? VoiceContent.fromJson(d) : null;
    } catch (_) {
      return null;
    }
  }
}

/// 图片消息 content（JSON 字符串）
class ImageContent {
  final String key;
  final String mime;
  final int size;
  final int width;
  final int height;

  const ImageContent({required this.key, required this.mime, required this.size, this.width = 0, this.height = 0});

  factory ImageContent.fromJson(Map<String, dynamic> j) => ImageContent(
        key: _str(j['key']),
        mime: _str(j['mime']),
        size: _int(j['size']),
        width: _int(j['width']),
        height: _int(j['height']),
      );

  Map<String, dynamic> toJson() => {'key': key, 'mime': mime, 'size': size, 'width': width, 'height': height};

  String encode() => jsonEncode(toJson());

  ImageContent withKey(String k) => ImageContent(key: k, mime: mime, size: size, width: width, height: height);

  /// 解析消息里的图片内容；非图片或已撤回返回 null
  static ImageContent? of(Message m) {
    if (m.msgType != msgImage || m.recalled) return null;
    try {
      final d = jsonDecode(m.content);
      return d is Map<String, dynamic> ? ImageContent.fromJson(d) : null;
    } catch (_) {
      return null;
    }
  }
}

/// 气泡显示尺寸：按原图比例缩放到最大 [maxW] x [maxH]（不放大）；缺少宽高时用方形占位
(double, double) imageBubbleSize(int width, int height, {double maxW = 260, double maxH = 320}) {
  if (width <= 0 || height <= 0) return (200, 200);
  var w = width.toDouble();
  var h = height.toDouble();
  final scale = [maxW / w, maxH / h, 1.0].reduce((a, b) => a < b ? a : b);
  w *= scale;
  h *= scale;
  // 极端长图 / 宽图保证最小可点区域
  return (w < 60 ? 60 : w, h < 60 ? 60 : h);
}

/// 在线状态（GET /api/presence 与 WS presence 事件）
class Presence {
  final int userId;
  final bool online;
  final DateTime? lastSeen;

  const Presence({required this.userId, this.online = false, this.lastSeen});

  factory Presence.fromJson(Map<String, dynamic> j) =>
      Presence(userId: _int(j['user_id']), online: _bool(j['online']), lastSeen: _dateOrNull(j['last_seen']));
}

/// POST /api/conversations/{id}/messages/{seq}/transcribe
class TranscriptResult {
  final String text;
  final bool cached;
  const TranscriptResult({required this.text, this.cached = false});
  factory TranscriptResult.fromJson(Map<String, dynamic> j) =>
      TranscriptResult(text: _str(j['text']), cached: _bool(j['cached']));
}

class SysUser {
  final int id;
  final String nickname;
  const SysUser(this.id, this.nickname);
  factory SysUser.fromJson(Map<String, dynamic> j) => SysUser(_int(j['id']), _str(j['nickname']));
}

/// 系统消息 content（JSON 字符串）
class SystemContent {
  final String op;
  final SysUser? actor;
  final List<SysUser> targets;
  final String name;
  final String value;
  final String text;

  const SystemContent({
    required this.op,
    this.actor,
    this.targets = const [],
    this.name = '',
    this.value = '',
    this.text = '',
  });

  factory SystemContent.fromJson(Map<String, dynamic> j) => SystemContent(
        op: _str(j['op']),
        actor: j['actor'] is Map<String, dynamic> ? SysUser.fromJson(j['actor']) : null,
        targets: ((j['targets'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SysUser.fromJson)
            .toList(),
        name: _str(j['name']),
        value: _str(j['value']),
        text: _str(j['text']),
      );

  static SystemContent? tryParse(String s) {
    try {
      final d = jsonDecode(s);
      return d is Map<String, dynamic> ? SystemContent.fromJson(d) : null;
    } catch (_) {
      return null;
    }
  }
}

class Conversation {
  final int id;
  final int type;
  final int lastSeq;
  final int modSeq;
  final int readSeq;
  final int joinSeq;
  final int unread;
  final DateTime updatedAt;
  final User? peer;
  final Message? lastMessage;
  final String lastSenderName;
  final String name;
  final int ownerId;
  final int myRole;
  final int memberCount;
  final List<User> membersPreview;
  final String announcement;
  final int announcementBy;
  final DateTime? announcementAt;

  const Conversation({
    required this.id,
    required this.type,
    this.lastSeq = 0,
    this.modSeq = 0,
    this.readSeq = 0,
    this.joinSeq = 0,
    this.unread = 0,
    required this.updatedAt,
    this.peer,
    this.lastMessage,
    this.lastSenderName = '',
    this.name = '',
    this.ownerId = 0,
    this.myRole = 0,
    this.memberCount = 0,
    this.membersPreview = const [],
    this.announcement = '',
    this.announcementBy = 0,
    this.announcementAt,
  });

  bool get isGroup => type == convGroup;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: _int(j['id']),
        type: _int(j['type']),
        lastSeq: _int(j['last_seq']),
        modSeq: _int(j['mod_seq']),
        readSeq: _int(j['read_seq']),
        joinSeq: _int(j['join_seq']),
        unread: _int(j['unread']),
        updatedAt: _date(j['updated_at']),
        peer: j['peer'] is Map<String, dynamic> ? User.fromJson(j['peer']) : null,
        lastMessage: j['last_message'] is Map<String, dynamic> ? Message.fromJson(j['last_message']) : null,
        lastSenderName: _str(j['last_sender_name']),
        name: _str(j['name']),
        ownerId: _int(j['owner_id']),
        myRole: _int(j['my_role']),
        memberCount: _int(j['member_count']),
        membersPreview: ((j['members_preview'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(User.fromJson)
            .toList(),
        announcement: _str(j['announcement']),
        announcementBy: _int(j['announcement_by']),
        announcementAt: _dateOrNull(j['announcement_at']),
      );

  Conversation copyWith({
    int? lastSeq,
    int? modSeq,
    int? readSeq,
    int? unread,
    DateTime? updatedAt,
    User? peer,
    Message? lastMessage,
    bool clearLastMessage = false,
    String? lastSenderName,
    String? name,
    List<User>? membersPreview,
    String? announcement,
    int? announcementBy,
    DateTime? announcementAt,
  }) =>
      Conversation(
        id: id,
        type: type,
        lastSeq: lastSeq ?? this.lastSeq,
        modSeq: modSeq ?? this.modSeq,
        readSeq: readSeq ?? this.readSeq,
        joinSeq: joinSeq,
        unread: unread ?? this.unread,
        updatedAt: updatedAt ?? this.updatedAt,
        peer: peer ?? this.peer,
        lastMessage: clearLastMessage ? null : (lastMessage ?? this.lastMessage),
        lastSenderName: lastSenderName ?? this.lastSenderName,
        name: name ?? this.name,
        ownerId: ownerId,
        myRole: myRole,
        memberCount: memberCount,
        membersPreview: membersPreview ?? this.membersPreview,
        announcement: announcement ?? this.announcement,
        announcementBy: announcementBy ?? this.announcementBy,
        announcementAt: announcementAt ?? this.announcementAt,
      );
}

class Member {
  final User user;
  final int role;
  final int readSeq;
  final DateTime? joinedAt;

  const Member({required this.user, this.role = 0, this.readSeq = 0, this.joinedAt});

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        user: User.fromJson((j['user'] as Map<String, dynamic>?) ?? const {}),
        role: _int(j['role']),
        readSeq: _int(j['read_seq']),
        joinedAt: _dateOrNull(j['joined_at']),
      );
}

class ClientConfig {
  final int recallSeconds;
  final int groupMaxMembers;
  final List<String> reactions;
  final bool voiceEnabled;
  final int? voiceMaxSeconds;
  final int? voiceMaxBytes;
  final int? voiceTtlDays;
  final bool imageEnabled;
  final int? imageMaxBytes;
  final bool presenceEnabled;
  final bool sttEnabled;

  const ClientConfig({
    this.recallSeconds = 120,
    this.groupMaxMembers = 500,
    this.reactions = defaultReactions,
    this.voiceEnabled = false,
    this.voiceMaxSeconds,
    this.voiceMaxBytes,
    this.voiceTtlDays,
    this.imageEnabled = false,
    this.imageMaxBytes,
    this.presenceEnabled = false,
    this.sttEnabled = false,
  });

  static const defaultReactions = ['❤️', '👍', '👎', '😂', '‼️', '❓'];

  factory ClientConfig.fromJson(Map<String, dynamic> j) => ClientConfig(
        recallSeconds: j['recall_seconds'] == null ? 120 : _int(j['recall_seconds']),
        groupMaxMembers: j['group_max_members'] == null ? 500 : _int(j['group_max_members']),
        reactions: (j['reactions'] as List?)?.map(_str).toList() ?? defaultReactions,
        voiceEnabled: _bool(j['voice_enabled']),
        voiceMaxSeconds: _intOrNull(j['voice_max_seconds']),
        voiceMaxBytes: _intOrNull(j['voice_max_bytes']),
        voiceTtlDays: _intOrNull(j['voice_ttl_days']),
        imageEnabled: _bool(j['image_enabled']),
        imageMaxBytes: _intOrNull(j['image_max_bytes']),
        presenceEnabled: _bool(j['presence_enabled']),
        sttEnabled: _bool(j['stt_enabled']),
      );
}

class AuthResult {
  final String token;
  final DateTime? expiresAt;
  final User user;

  const AuthResult({required this.token, this.expiresAt, required this.user});

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token: _str(j['token']),
        expiresAt: _dateOrNull(j['expires_at']),
        user: User.fromJson((j['user'] as Map<String, dynamic>?) ?? const {}),
      );
}

class PresignResult {
  final String key;
  final String url;
  final String method;
  final Map<String, String> headers;
  final DateTime? expiresAt;

  const PresignResult({
    required this.key,
    required this.url,
    this.method = 'PUT',
    this.headers = const {},
    this.expiresAt,
  });

  factory PresignResult.fromJson(Map<String, dynamic> j) => PresignResult(
        key: _str(j['key']),
        url: _str(j['url']),
        method: j['method'] == null ? 'PUT' : _str(j['method']),
        headers: ((j['headers'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
        expiresAt: _dateOrNull(j['expires_at']),
      );
}

class MediaInfo {
  final String url;
  final String mime;
  final int size;
  const MediaInfo({required this.url, this.mime = '', this.size = 0});
  factory MediaInfo.fromJson(Map<String, dynamic> j) =>
      MediaInfo(url: _str(j['url']), mime: _str(j['mime']), size: _int(j['size']));
}
