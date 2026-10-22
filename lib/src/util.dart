import 'models.dart';

String _pad(int n) => n.toString().padLeft(2, '0');

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String hm(DateTime d) => '${_pad(d.hour)}:${_pad(d.minute)}';

/// 会话列表时间：今天 HH:mm / 昨天 / 周X / M月D日 / yyyy/M/D
String listTime(DateTime d, [DateTime? now]) {
  now ??= DateTime.now();
  if (_sameDay(d, now)) return hm(d);
  final y = now.subtract(const Duration(days: 1));
  if (_sameDay(d, y)) return '昨天';
  final diff = now.difference(d).inMilliseconds / 86400000;
  if (diff < 7) return '周${'日一二三四五六'[d.weekday % 7]}';
  if (d.year == now.year) return '${d.month}月${d.day}日';
  return '${d.year}/${d.month}/${d.day}';
}

/// 聊天中的日期分隔
String dayLabel(DateTime d, [DateTime? now]) {
  final t = listTime(d, now);
  return RegExp(r'^\d{2}:\d{2}$').hasMatch(t) ? '今天 ${hm(d)}' : '$t ${hm(d)}';
}

String displayName(User? u) {
  if (u == null) return '未知用户';
  if (u.nickname.isNotEmpty) return u.nickname;
  if (u.email.isNotEmpty) return u.email.split('@').first;
  return '未知用户';
}

String initialOf(String name) {
  final t = name.trim();
  if (t.isEmpty) return '?';
  return String.fromCharCode(t.runes.first).toUpperCase();
}

String convTitle(Conversation? c) {
  if (c == null) return '';
  if (c.isGroup) return c.name.isNotEmpty ? c.name : '群聊';
  return displayName(c.peer);
}

/// 系统消息文本：把自己替换成“你”
String systemText(Message m, int? meId) {
  final p = SystemContent.tryParse(m.content);
  if (p == null) return m.content;
  String who(SysUser? u) => u == null ? '' : (u.id == meId ? '你' : u.nickname);
  final names = p.targets.map(who).join('、');
  final a = who(p.actor);
  switch (p.op) {
    case 'create':
      return '$a 创建了群聊“${p.name}”${names.isNotEmpty ? '，并邀请了 $names' : ''}';
    case 'join':
      return '$a 邀请 $names 加入了群聊';
    case 'remove':
      return '$a 将 $names 移出了群聊';
    case 'leave':
      return '$a 退出了群聊${names.isNotEmpty ? '，$names 成为新群主' : ''}';
    case 'rename':
      return '$a 将群名修改为“${p.name}”';
    case 'announce':
      return p.value.isNotEmpty ? '$a 更新了群公告' : '$a 清空了群公告';
    case 'role':
      return p.value == 'admin' ? '$a 将 $names 设为管理员' : '$a 取消了 $names 的管理员';
  }
  return p.text.isNotEmpty ? p.text : '[系统消息]';
}

/// 文件大小展示
String fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1048576).toStringAsFixed(1)} MB';
  return '${(n / 1073741824).toStringAsFixed(2)} GB';
}

/// 通话时长 mm:ss（超过 1 小时带小时）
String fmtCallDuration(int ms) {
  final s = (ms / 1000).floor();
  final mm = (s % 3600) ~/ 60;
  final ss = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(mm)}:${two(ss)}' : '${two(mm)}:${two(ss)}';
}

/// 通话记录的展示文案（SPEC v0.4.0 §1.4），解析失败时兜底
String callText(Message m) {
  final c = CallContent.of(m);
  if (c == null) return '[通话]';
  final kind = c.isVideo ? '视频通话' : '语音通话';
  return switch (c.outcome) {
    'completed' => '$kind ${fmtCallDuration(c.durationMs)}',
    'missed' => '$kind 未接听',
    'rejected' => '$kind 对方已拒绝',
    'cancelled' => '$kind 已取消',
    'busy' => '$kind 对方忙线',
    'failed' => '$kind 连接失败',
    _ => '[$kind]',
  };
}

/// 会话列表 / 引用里的单行预览
String previewOf(Message m, int? meId, String Function(int id) senderName) {
  if (m.recalled) return '${m.senderId == meId ? '你' : senderName(m.senderId)}撤回了一条消息';
  if (m.msgType == msgSystem) return systemText(m, meId);
  if (m.msgType == msgText) return m.content;
  if (m.msgType == msgVoice) return '[语音]';
  if (m.msgType == msgImage) return '[图片]';
  if (m.msgType == msgVideo) return '[视频]';
  if (m.msgType == msgFile) {
    final f = FileContent.of(m);
    final name = f?.name ?? '';
    return name.isEmpty ? '[文件]' : '[文件] $name';
  }
  if (m.msgType == msgCall) return '[${CallContent.of(m)?.isVideo == true ? '视频通话' : '语音通话'}]';
  return unsupportedText;
}

/// 本客户端不认识的消息类型
const String unsupportedText = '[不支持的消息，请升级]';

/// 引用 / 回复栏里的短预览（不处理撤回）
String shortPreview(Message m) => switch (m.msgType) {
      msgText => m.content,
      msgVoice => '[语音]',
      msgImage => '[图片]',
      msgVideo => '[视频]',
      msgFile => '[文件]',
      msgCall => '[通话]',
      _ => '[消息]',
    };

/// “最后在线”时间：今天 14:03 / 昨天 14:03 / 周一 14:03 / 10月1日 14:03
String lastSeenText(DateTime? d, [DateTime? now]) => d == null ? '离线' : '最后在线 ${dayLabel(d, now)}';

/// 自己发出的系统消息是否表示“我已不在群里”（退群 / 被移出）
bool isMyExit(Message m, int? meId) {
  final p = SystemContent.tryParse(m.content);
  if (p == null) return false;
  return (p.op == 'leave' && p.actor?.id == meId) || (p.op == 'remove' && p.targets.any((t) => t.id == meId));
}
