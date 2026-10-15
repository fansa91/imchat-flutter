import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store.dart';
import 'image_bubble.dart';
import 'voice_player.dart';

/// 消息操作：表情回应 + 回复 / 复制 / 撤回 / 删除（仅自己）
Future<void> showMessageMenu(
  BuildContext context, {
  required Message m,
  required void Function(Message) onReply,
  String? readInfo,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _MessageMenu(m: m, onReply: onReply, readInfo: readInfo),
  );
}

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({required this.m, required this.onReply, this.readInfo});
  final Message m;
  final void Function(Message) onReply;
  final String? readInfo;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final confirmed = m.seq > 0;
    final mine = m.senderId == store.me?.id;
    final reactions = store.config.reactions;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (confirmed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                children: [
                  for (final e in reactions)
                    IconButton.filledTonal(
                      isSelected: m.reactions.any((r) => r.emoji == e && r.userIds.contains(store.me?.id)),
                      onPressed: () {
                        Navigator.pop(context);
                        store.react(m, e);
                      },
                      icon: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                ],
              ),
            ),
          if (readInfo != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(readInfo!, style: TextStyle(color: cs.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          if (confirmed)
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('回复'),
              onTap: () {
                Navigator.pop(context);
                onReply(m);
              },
            ),
          if (m.msgType == msgText)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.content));
                Navigator.pop(context);
                store.showToast('已复制');
              },
            ),
          if (store.canTranscribe(m))
            ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: const Text('转文字'),
              onTap: () {
                Navigator.pop(context);
                store.transcribe(m);
              },
            ),
          if (m.msgType == msgVoice && store.transcriptOf(m) != null)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制文字'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: store.transcriptOf(m)!));
                Navigator.pop(context);
                store.showToast('已复制');
              },
            ),
          if (m.msgType == msgImage && !m.recalled && store.imageState(m) == MediaState.ready)
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('保存图片'),
              onTap: () async {
                Navigator.pop(context);
                final f = await store.imageFile(m);
                if (f == null) return;
                try {
                  final msg = await saveImage(f, suggestedImageName(m, f));
                  if (msg != null) store.showToast(msg);
                } catch (_) {
                  store.showToast('保存失败');
                }
              },
            ),
          if (store.canRecall(m))
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('撤回'),
              subtitle: Text('${(store.config.recallSeconds / 60).round()} 分钟内可撤回'),
              onTap: () {
                Navigator.pop(context);
                context.read<VoicePlayer>().stopIf(store.voiceKeyOf(m));
                store.recall(m);
              },
            ),
          if (mine && m.status == MsgStatus.failed)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重新发送'),
              onTap: () {
                Navigator.pop(context);
                store.retry(m);
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: cs.error),
            title: Text(confirmed ? '删除（仅自己）' : '删除', style: TextStyle(color: cs.error)),
            onTap: () {
              Navigator.pop(context);
              if (confirmed) context.read<VoicePlayer>().stopIf(store.voiceKeyOf(m));
              store.deleteForMe(m);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
