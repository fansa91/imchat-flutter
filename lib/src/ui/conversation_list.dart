import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../socket.dart';
import '../store.dart';
import '../util.dart';
import 'avatar.dart';

class ConversationList extends StatelessWidget {
  const ConversationList({
    super.key,
    required this.activeId,
    required this.onOpen,
    required this.onNew,
    required this.onSettings,
  });

  final int? activeId;
  final void Function(int id) onOpen;
  final VoidCallback onNew;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final list = store.sortedConversations;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(tooltip: '主题与账号', icon: const Icon(Icons.palette_outlined), onPressed: onSettings),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-chat',
        onPressed: onNew,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('新聊天'),
      ),
      body: Column(
        children: [
          if (store.conn != ConnState.online)
            Material(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Icon(Icons.cloud_off, size: 18, color: cs.onErrorContainer),
                  const SizedBox(width: 8),
                  Text(
                    store.conn == ConnState.connecting ? '正在连接…' : '连接已断开，正在重试',
                    style: TextStyle(color: cs.onErrorContainer),
                  ),
                ]),
              ),
            ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('还没有会话', style: TextStyle(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 12),
                      FilledButton.tonal(onPressed: onNew, child: const Text('发起聊天')),
                    ]),
                  )
                : RefreshIndicator(
                    onRefresh: () => store.loadConversations().catchError((_) => <Conversation>[]),
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 88, top: 4),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _ConvTile(
                        c: list[i],
                        active: list[i].id == activeId,
                        onOpen: onOpen,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConvTile extends StatelessWidget {
  const _ConvTile({required this.c, required this.active, required this.onOpen});
  final Conversation c;
  final bool active;
  final void Function(int) onOpen;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final meId = store.me?.id;
    final typing = store.typing[c.id]?.active ?? false;
    final last = c.lastMessage;
    String senderName(int id) => store.users[id] != null
        ? displayName(store.users[id])
        : (id == last?.senderId && c.lastSenderName.isNotEmpty ? c.lastSenderName : '群成员');
    var preview = '开始聊天吧';
    if (typing) {
      preview = '正在输入…';
    } else if (last != null) {
      final body = previewOf(last, meId, senderName);
      final plain = !last.recalled && last.msgType != msgSystem;
      if (plain && last.senderId == meId) {
        preview = '我：$body';
      } else if (plain && c.isGroup) {
        preview = '${senderName(last.senderId)}：$body';
      } else {
        preview = body;
      }
    }
    final unread = c.unread > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: ListTile(
        selected: active,
        selectedTileColor: cs.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: ConvAvatar(conv: c, size: 48, online: !c.isGroup && c.peer != null && store.isOnline(c.peer!.id)),
        title: Row(children: [
          Expanded(
            child: Text(
              convTitle(c),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.titleMedium?.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            last != null ? listTime(last.createdAt) : '',
            style: tt.labelSmall?.copyWith(color: unread ? cs.primary : cs.onSurfaceVariant),
          ),
        ]),
        subtitle: Row(children: [
          Expanded(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodyMedium?.copyWith(
                color: typing ? cs.primary : (unread ? cs.onSurface : cs.onSurfaceVariant),
                fontWeight: unread ? FontWeight.w500 : null,
              ),
            ),
          ),
          if (unread) ...[
            const SizedBox(width: 8),
            Badge(
              label: Text(c.unread > 99 ? '99+' : '${c.unread}'),
              backgroundColor: cs.primary,
              textColor: cs.onPrimary,
            ),
          ],
        ]),
        onTap: () => onOpen(c.id),
      ),
    );
  }
}
