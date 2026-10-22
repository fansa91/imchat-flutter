import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../util.dart';

/// 头像图片内存缓存：完整 URL -> 字节（URL 带 ?v= 版本参数，变更即自然失效）
final Map<String, Uint8List> _avatarBytes = {};
final Map<String, Future<Uint8List?>> _avatarPending = {};

Future<Uint8List?> _fetchAvatar(String url, String token) {
  final hit = _avatarBytes[url];
  if (hit != null) return Future.value(hit);
  return _avatarPending.putIfAbsent(url, () async {
    try {
      final res = await http.get(Uri.parse(url), headers: token.isEmpty ? null : {'Authorization': 'Bearer $token'});
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      _avatarBytes[url] = res.bodyBytes;
      return res.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      _avatarPending.remove(url);
    }
  });
}

/// 服务端拼装的相对头像路径（/api/users/{id}/avatar?v=...）需拼服务器 base。
/// 注意：相对路径自带 ?v= 查询串，必须先 parse 把 path 与 query 分开再合并；
/// 整体塞进 replace(path:) 会把 ? 编码成 %3F，请求变成 /avatar%3Fv=... 而 404。
String? resolveAvatarUrl(String server, String avatarUrl) {
  if (avatarUrl.isEmpty) return null;
  if (avatarUrl.startsWith('http://') || avatarUrl.startsWith('https://')) return avatarUrl;
  final base = Uri.parse(normalizeServer(server));
  final rel = Uri.parse(avatarUrl);
  return base.replace(path: '${base.path}${rel.path}', query: rel.query.isEmpty ? null : rel.query).toString();
}

/// 根据用户 ID 选一组 M3 容器色作为头像底色
(Color, Color) avatarColors(ColorScheme cs, int id) => switch (id % 3) {
      0 => (cs.primaryContainer, cs.onPrimaryContainer),
      1 => (cs.secondaryContainer, cs.onSecondaryContainer),
      _ => (cs.tertiaryContainer, cs.onTertiaryContainer),
    };

class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, this.user, this.size = 40});
  final User? user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final (bg, fg) = avatarColors(Theme.of(context).colorScheme, user?.id ?? 0);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        initialOf(store.displayOf(user)),
        style: TextStyle(color: fg, fontSize: size * 0.42, fontWeight: FontWeight.w500),
      ),
    );
    final url = user?.avatarUrl ?? '';
    if (url.isEmpty) return fallback;
    final full = resolveAvatarUrl(store.api.server, url);
    if (full == null) return fallback;
    // 带 Authorization 头拉取（服务端 302 到预签名地址，http 自动跟随重定向）
    return FutureBuilder<Uint8List?>(
      future: _fetchAvatar(full, store.api.token),
      builder: (context, snap) {
        final bytes = snap.data ?? _avatarBytes[full];
        if (bytes == null) return fallback;
        return ClipOval(
          child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
        );
      },
    );
  }
}

/// 群头像：最多 4 个成员首字拼成 2x2
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({super.key, required this.users, this.size = 40});
  final List<User> users;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = users.take(4).toList();
    if (list.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: cs.secondaryContainer, shape: BoxShape.circle),
        child: Icon(Icons.group, size: size * 0.55, color: cs.onSecondaryContainer),
      );
    }
    if (list.length == 1) return UserAvatar(user: list.first, size: size);
    final cell = size / 2;
    final store = context.read<ChatStore>();
    Widget tile(User u) {
      final (bg, fg) = avatarColors(cs, u.id);
      return Container(
        width: cell,
        height: cell,
        color: bg,
        alignment: Alignment.center,
        child: Text(initialOf(store.displayOf(u)), style: TextStyle(color: fg, fontSize: cell * 0.5)),
      );
    }

    Widget body;
    if (list.length == 2) {
      body = Row(children: [
        SizedBox(width: cell, height: size, child: tile(list[0])),
        SizedBox(width: cell, height: size, child: tile(list[1])),
      ]);
    } else {
      body = Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [tile(list[0]), if (list.length > 3) tile(list[3])]),
        Row(children: [tile(list[1]), tile(list[2])]),
      ]);
    }
    return ClipOval(child: SizedBox(width: size, height: size, child: body));
  }
}

class ConvAvatar extends StatelessWidget {
  const ConvAvatar({super.key, this.conv, this.size = 40, this.online = false});
  final Conversation? conv;
  final double size;

  /// 单聊对方在线时右下角显示绿点
  final bool online;

  @override
  Widget build(BuildContext context) {
    if (conv?.isGroup == true) return GroupAvatar(users: conv!.membersPreview, size: size);
    final avatar = UserAvatar(user: conv?.peer, size: size);
    return online ? OnlineDot(size: size, child: avatar) : avatar;
  }
}

/// 头像右下角的在线绿点
class OnlineDot extends StatelessWidget {
  const OnlineDot({super.key, required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = (size * 0.28).clamp(8.0, 14.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        child,
        Positioned(
          right: 0,
          bottom: 0,
          child: Semantics(
            label: '在线',
            child: Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                color: const Color(0xFF34C759),
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
