import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../store.dart';
import 'call_page.dart';
import 'chat_view.dart';
import 'conversation_list.dart';
import 'dialogs.dart';
import 'group_info.dart';

/// 自适应布局：宽度 >= 840 双栏（列表 + 聊天），否则单栏（列表 / 聊天切换）
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  static const double twoPaneBreakpoint = 840;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int? _selected;

  void _open(int id) => setState(() => _selected = id);

  void _close() {
    context.read<ChatStore>().closeConversation();
    setState(() => _selected = null);
  }

  Future<void> _newChat() async {
    final id = await showDialog<int>(context: context, builder: (_) => const NewChatDialog());
    if (id != null && mounted) _open(id);
  }

  void _settings() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => const SettingsSheet(),
      );

  void _info(int id) => showGroupInfo(context, id);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    // 通话中/来电时全屏覆盖（通话状态在 CallManager 里，单独监听）
    return ListenableBuilder(
      listenable: store.calls,
      builder: (context, _) => Stack(children: [
        _buildMain(context, store),
        if (store.calls.active) const Positioned.fill(child: CallPage()),
      ]),
    );
  }

  Widget _buildMain(BuildContext context, ChatStore store) {
    // 会话已不存在（退群 / 被移出）
    if (_selected != null && !store.convs.containsKey(_selected)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selected != null && !store.convs.containsKey(_selected)) setState(() => _selected = null);
      });
    }
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= HomePage.twoPaneBreakpoint;
      final list = ConversationList(
        activeId: wide ? _selected : null,
        onOpen: _open,
        onNew: _newChat,
        onSettings: _settings,
      );
      final sel = _selected;
      if (wide) {
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                SizedBox(width: box.maxWidth >= 1200 ? 400 : 360, child: list),
                VerticalDivider(width: 1, color: cs.outlineVariant),
                Expanded(
                  child: sel == null || !store.convs.containsKey(sel)
                      ? const _EmptyPane()
                      : ChatView(key: ValueKey(sel), id: sel, showBack: false, onBack: _close, onInfo: () => _info(sel)),
                ),
              ],
            ),
          ),
        );
      }
      if (sel != null && store.convs.containsKey(sel)) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _close();
          },
          child: Scaffold(
            body: SafeArea(
              child: ChatView(key: ValueKey(sel), id: sel, showBack: true, onBack: _close, onInfo: () => _info(sel)),
            ),
          ),
        );
      }
      return Scaffold(body: SafeArea(child: list));
    });
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surfaceContainerLowest,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 72, color: cs.outline),
          const SizedBox(height: 12),
          Text('选择一个会话开始聊天', style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
