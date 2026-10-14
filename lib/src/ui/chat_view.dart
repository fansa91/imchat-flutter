import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../settings.dart';
import '../store.dart';
import '../util.dart';
import 'avatar.dart';
import 'composer.dart';
import 'message_item.dart';
import 'message_menu.dart';

const Duration _gap = Duration(minutes: 5); // 超过 5 分钟显示时间分隔

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.id, required this.showBack, required this.onBack, required this.onInfo});
  final int id;
  final bool showBack;
  final VoidCallback onBack;
  final VoidCallback onInfo;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  final _composer = GlobalKey<ComposerState>();
  final Map<int, GlobalKey> _keys = {};
  Message? _replyTo;
  int _flash = 0;
  late final ChatStore _store = context.read<ChatStore>();

  @override
  void initState() {
    super.initState();
    _store.openConversation(widget.id);
    _scroll.addListener(_onScroll);
    if (isDesktop) WidgetsBinding.instance.addPostFrameCallback((_) => _composer.currentState?.focus());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 列表是倒序的：maxScrollExtent 一侧是更早的消息
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _store.loadMore(widget.id);
  }

  GlobalKey _keyFor(int seq) => _keys.putIfAbsent(seq, GlobalKey.new);

  Future<void> _jumpTo(int seq) async {
    final ok = await _store.ensureLoaded(widget.id, seq);
    if (!ok) {
      _store.showToast('原消息已不可见');
      return;
    }
    // ListView 懒加载：逐屏往上滚，直到目标被构建出来
    for (var i = 0; i < 60 && mounted; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final ctx = _keys[seq]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 300));
        setState(() => _flash = seq);
        Timer(const Duration(milliseconds: 1600), () {
          if (mounted && _flash == seq) setState(() => _flash = 0);
        });
        return;
      }
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.pixels >= pos.maxScrollExtent) {
        if (i > 3) return;
        continue;
      }
      _scroll.jumpTo((pos.pixels + pos.viewportDimension * 0.8).clamp(0, pos.maxScrollExtent));
    }
  }

  void _openMenu(Message m, String Function(int) readLabel) {
    final me = _store.me?.id;
    showMessageMenu(
      context,
      m: m,
      readInfo: m.senderId == me && m.seq > 0 ? readLabel(m.seq) : null,
      onReply: (m) {
        setState(() => _replyTo = m);
        _composer.currentState?.focus();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final settings = context.read<Settings>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final id = widget.id;
    final conv = store.convs[id];
    final t = store.threads[id];
    final me = store.me!;
    final isGroup = conv?.isGroup ?? false;
    final typing = store.typing[id];
    final typingOn = typing?.active ?? false;
    final reads = store.reads[id] ?? const <int, int>{};
    if (conv != null && conv.readSeq < conv.lastSeq && store.foreground && store.activeId == id && (t?.loaded ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => store.markRead(id));
    }

    final items = t?.items ?? const <Message>[];
    final all = [...items, ...?t?.pending];

    // 已读：单聊看对方，群聊统计“N人已读”
    final others = reads.entries.where((e) => e.key != me.id).toList();
    int readCount(int seq) => others.where((e) => e.value >= seq).length;
    final memberCount = (conv?.memberCount ?? 0) > 0 ? conv!.memberCount : others.length + 1;
    String readLabel(int seq) {
      final n = readCount(seq);
      if (!isGroup) return n > 0 ? '已读' : '已送达';
      if (n == 0) return '已送达';
      return n >= memberCount - 1 ? '全部已读' : '$n人已读';
    }

    var lastMine = -1;
    for (var i = 0; i < all.length; i++) {
      final m = all[i];
      if (m.senderId == me.id && m.msgType != msgSystem && !m.recalled) lastMine = i;
    }

    final subtitle = typingOn
        ? (isGroup ? '${displayName(store.users[typing!.uid])} 正在输入…' : '正在输入…')
        : (isGroup ? '${conv?.memberCount ?? ''} 位成员' : (conv?.peer?.email ?? ''));

    final annAt = conv?.announcementAt?.toUtc().toIso8601String() ?? '';
    final showAnn = isGroup && (conv?.announcement.isNotEmpty ?? false) && settings.annDismissed(id) != annAt;

    // 按时间正序构建条目，再倒序交给 reverse ListView
    final entries = <Widget>[];
    bool plain(Message? x) => x != null && x.msgType != msgSystem && !x.recalled;
    for (var i = 0; i < all.length; i++) {
      final m = all[i];
      final prev = i > 0 ? all[i - 1] : null;
      final next = i + 1 < all.length ? all[i + 1] : null;
      final showTime = prev == null || m.createdAt.difference(prev.createdAt) > _gap;
      final nextBreak = next == null || next.createdAt.difference(m.createdAt) > _gap;
      final first = showTime || !plain(prev) || prev.senderId != m.senderId;
      final last = nextBreak || !plain(next) || next.senderId != m.senderId;
      final replyOrig = m.replyTo == null ? null : items.where((x) => x.seq == m.replyTo!.seq).firstOrNull;
      if (showTime) {
        entries.add(Padding(
          key: ValueKey('t:${m.clientMsgId}:${m.seq}'),
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Center(child: Text(dayLabel(m.createdAt), style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant))),
        ));
      }
      entries.add(KeyedSubtree(
        key: m.seq > 0 ? _keyFor(m.seq) : ValueKey('p:${m.clientMsgId}'),
        child: MessageItem(
          m: m,
          isGroup: isGroup,
          first: first,
          last: last,
          replyOrig: replyOrig,
          highlighted: _flash != 0 && _flash == m.seq,
          onMenu: (m) => _openMenu(m, readLabel),
          onJump: _jumpTo,
          onReedit: (txt) => _composer.currentState?.setText(txt),
        ),
      ));
      if (i == lastMine) {
        entries.add(Padding(
          key: const ValueKey('receipt'),
          padding: const EdgeInsets.only(right: 16, top: 2),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              m.status == MsgStatus.sending
                  ? '发送中…'
                  : m.status == MsgStatus.failed
                      ? '发送失败'
                      : readLabel(m.seq),
              style: tt.labelSmall?.copyWith(color: m.status == MsgStatus.failed ? cs.error : cs.onSurfaceVariant),
            ),
          ),
        ));
      }
    }
    if (typingOn) {
      entries.add(Padding(
        key: const ValueKey('typing'),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
            child: Text('•••', style: TextStyle(color: cs.onSurfaceVariant, letterSpacing: 2)),
          ),
        ),
      ));
    }
    if (t != null && t.loaded && !t.hasMore && items.length >= 50) {
      entries.insert(
        0,
        Padding(
          key: const ValueKey('end'),
          padding: const EdgeInsets.all(12),
          child: Center(child: Text('以上是全部消息', style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant))),
        ),
      );
    }
    if (t?.loadingMore ?? false) {
      entries.insert(
        0,
        const Padding(
          key: ValueKey('loading'),
          padding: EdgeInsets.all(12),
          child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      );
    }
    final reversed = entries.reversed.toList();

    Widget body;
    if (t == null || !t.loaded) {
      body = const Center(child: CircularProgressIndicator());
    } else if (all.isEmpty) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ConvAvatar(conv: conv, size: 72),
          const SizedBox(height: 12),
          Text('和 ${convTitle(conv)} 打个招呼吧', style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      );
    } else {
      body = ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        itemCount: reversed.length,
        findChildIndexCallback: (key) {
          final i = reversed.indexWhere((w) => w.key == key);
          return i < 0 ? null : i;
        },
        itemBuilder: (_, i) => reversed[i],
      );
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: widget.showBack ? 0 : 16,
        leading: widget.showBack
            ? IconButton(tooltip: '返回', icon: const Icon(Icons.arrow_back), onPressed: widget.onBack)
            : null,
        title: Row(children: [
          ConvAvatar(conv: conv, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(convTitle(conv), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: typingOn ? cs.primary : cs.onSurfaceVariant),
              ),
            ]),
          ),
        ]),
        actions: [
          if (isGroup) IconButton(tooltip: '群聊信息', icon: const Icon(Icons.info_outline), onPressed: widget.onInfo),
        ],
      ),
      body: Column(children: [
        if (showAnn)
          Material(
            color: cs.secondaryContainer,
            child: InkWell(
              onTap: widget.onInfo,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                child: Row(children: [
                  Icon(Icons.campaign_outlined, size: 20, color: cs.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(conv!.announcement,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSecondaryContainer)),
                  ),
                  IconButton(
                    tooltip: '关闭公告',
                    icon: Icon(Icons.close, size: 18, color: cs.onSecondaryContainer),
                    onPressed: () async {
                      await settings.dismissAnn(id, annAt);
                      if (mounted) setState(() {});
                    },
                  ),
                ]),
              ),
            ),
          ),
        Expanded(child: body),
        Composer(
          key: _composer,
          id: id,
          replyTo: _replyTo,
          onCancelReply: () => setState(() => _replyTo = null),
          onSent: () {
            setState(() => _replyTo = null);
            if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          },
        ),
      ]),
    );
  }
}
