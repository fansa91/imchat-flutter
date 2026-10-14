import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store.dart';
import '../util.dart';
import 'avatar.dart';
import 'voice_bubble.dart';

class MessageItem extends StatelessWidget {
  const MessageItem({
    super.key,
    required this.m,
    required this.isGroup,
    required this.first,
    required this.last,
    required this.highlighted,
    required this.onMenu,
    required this.onJump,
    required this.onReedit,
    this.replyOrig,
  });

  final Message m;
  final bool isGroup;
  final bool first;
  final bool last;
  final bool highlighted;
  final Message? replyOrig;
  final void Function(Message m) onMenu;
  final void Function(int seq) onJump;
  final void Function(String text) onReedit;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final meId = store.me?.id;
    final mine = m.senderId == meId;

    if (m.msgType == msgSystem) {
      return _SysLine(text: systemText(m, meId));
    }
    if (m.recalled) {
      final draft = mine ? store.recalledDrafts['${m.conversationId}:${m.seq}'] : null;
      return _SysLine(
        text: '${mine ? '你' : store.nameOf(m.senderId)}撤回了一条消息',
        action: draft == null ? null : TextButton(onPressed: () => onReedit(draft), child: const Text('重新编辑')),
      );
    }

    final bubbleColor = mine ? cs.primary : cs.surfaceContainerHigh;
    final fg = mine ? cs.onPrimary : cs.onSurface;
    const r = Radius.circular(20);
    const small = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: !mine && !first ? small : r,
      bottomLeft: !mine && !last ? small : r,
      topRight: mine && !first ? small : r,
      bottomRight: mine && !last ? small : r,
    );

    final reply = m.replyTo;
    final origRecalled = replyOrig != null ? replyOrig!.recalled : (reply?.recalled ?? false);
    String? origPreview = reply?.preview;
    if (replyOrig != null) {
      origPreview = replyOrig!.msgType == msgText
          ? replyOrig!.content
          : replyOrig!.msgType == msgVoice
              ? '[语音]'
              : '[消息]';
    }

    Widget content;
    if (m.msgType == msgVoice) {
      content = VoiceBubble(m: m, mine: mine);
    } else if (m.msgType == msgText) {
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(m.content, style: tt.bodyLarge?.copyWith(color: fg)),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text('[暂不支持的消息类型]', style: tt.bodyLarge?.copyWith(color: fg)),
      );
    }

    final bubble = Opacity(
      opacity: m.status == MsgStatus.sending ? 0.7 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: highlighted ? cs.tertiary : bubbleColor,
          borderRadius: radius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reply != null)
              InkWell(
                onTap: () => onJump(reply.seq),
                child: Container(
                  margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border(left: BorderSide(color: fg.withValues(alpha: 0.6), width: 3)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(store.nameOf(reply.senderId),
                        style: tt.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                    Text(
                      reply.missing ? '原消息不可见' : (origRecalled ? '原消息已撤回' : (origPreview ?? '')),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: fg.withValues(alpha: 0.85)),
                    ),
                  ]),
                ),
              ),
            content,
          ],
        ),
      ),
    );

    final interactive = GestureDetector(
      onLongPress: () {
        HapticFeedback.selectionClick();
        onMenu(m);
      },
      onSecondaryTap: () => onMenu(m),
      child: Tooltip(
        message: hm(m.createdAt),
        waitDuration: const Duration(milliseconds: 800),
        child: bubble,
      ),
    );

    final maxW = MediaQuery.sizeOf(context).width;
    final row = Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (isGroup && !mine)
          SizedBox(
            width: 36,
            child: last ? UserAvatar(user: store.users[m.senderId], size: 28) : null,
          ),
        if (mine && m.status == MsgStatus.failed)
          IconButton(
            tooltip: '发送失败，点击重发',
            icon: Icon(Icons.error, color: cs.error),
            onPressed: () => store.retry(m),
          ),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW < 600 ? maxW * 0.78 : 520),
            child: Column(
              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (isGroup && !mine && first)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 2),
                    child: Text(store.nameOf(m.senderId), style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                interactive,
                if (m.reactions.isNotEmpty) _Reactions(m: m, meId: meId),
              ],
            ),
          ),
        ),
        if (m.seq > 0)
          _HoverMore(onTap: () => onMenu(m)),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(left: 8, right: 8, top: first ? 6 : 1, bottom: 1),
      child: row,
    );
  }
}

/// 桌面端悬停显示的“更多”按钮
class _HoverMore extends StatelessWidget {
  const _HoverMore({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final desktop = platform == TargetPlatform.macOS || platform == TargetPlatform.linux || platform == TargetPlatform.windows;
    if (!desktop) return const SizedBox.shrink();
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      tooltip: '回应 / 更多',
      icon: Icon(Icons.add_reaction_outlined, color: Theme.of(context).colorScheme.outline),
      onPressed: onTap,
    );
  }
}

class _SysLine extends StatelessWidget {
  const _SysLine({required this.text, this.action});
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ?action,
        ],
      ),
    );
  }
}

class _Reactions extends StatelessWidget {
  const _Reactions({required this.m, required this.meId});
  final Message m;
  final int? meId;
  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final r in m.reactions)
            Material(
              color: r.userIds.contains(meId) ? cs.secondaryContainer : cs.surfaceContainerHighest,
              shape: StadiumBorder(
                side: BorderSide(color: r.userIds.contains(meId) ? cs.secondary : cs.outlineVariant),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => store.react(m, r.emoji),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(r.count > 1 ? '${r.emoji} ${r.count}' : r.emoji, style: const TextStyle(fontSize: 14)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
