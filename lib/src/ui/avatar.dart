import 'package:flutter/material.dart';

import '../models.dart';
import '../util.dart';

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
    final (bg, fg) = avatarColors(Theme.of(context).colorScheme, user?.id ?? 0);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        initialOf(displayName(user)),
        style: TextStyle(color: fg, fontSize: size * 0.42, fontWeight: FontWeight.w500),
      ),
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
    Widget tile(User u) {
      final (bg, fg) = avatarColors(cs, u.id);
      return Container(
        width: cell,
        height: cell,
        color: bg,
        alignment: Alignment.center,
        child: Text(initialOf(displayName(u)), style: TextStyle(color: fg, fontSize: cell * 0.5)),
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
