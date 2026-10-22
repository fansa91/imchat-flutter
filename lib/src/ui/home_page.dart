import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../store.dart';
import 'avatar.dart';
import 'call_page.dart';
import 'chat_view.dart';
import 'conversation_list.dart';
import 'dialogs.dart';
import 'friends_page.dart';
import 'group_call_page.dart';
import 'group_info.dart';
import 'me_page.dart';

/// 主界面：消息 / 好友 / 我的 三入口（SPEC v0.5.0 §2.2）。
/// 窄屏底部导航栏；宽屏左侧导航栏 + 双栏（列表 + 聊天）。
/// 自适应布局：宽度 >= 840 双栏，否则单栏（列表 / 聊天切换）。
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  static const double twoPaneBreakpoint = 840;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int? _selected;
  int _tab = 0; // 0 消息 1 好友 2 我的

  void _open(int id) => setState(() {
        _selected = id;
        _tab = 0;
      });

  void _close() {
    context.read<ChatStore>().closeConversation();
    setState(() => _selected = null);
  }

  Future<void> _newChat() async {
    final id = await showDialog<int>(context: context, builder: (_) => const NewChatDialog());
    if (id != null && mounted) _open(id);
  }

  void _info(int id) => showGroupInfo(context, id);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    // 通话中/来电时全屏覆盖（通话状态在各 Manager 里，单独监听）
    return ListenableBuilder(
      listenable: Listenable.merge([store.calls, store.groupCalls]),
      builder: (context, _) => Stack(children: [
        _buildMain(context, store),
        if (store.calls.active)
          const Positioned.fill(child: CallPage())
        else if (store.groupCalls.active)
          const Positioned.fill(child: GroupCallPage()),
        if (!store.calls.active && !store.groupCalls.active && store.groupCalls.invite != null)
          Positioned(left: 12, right: 12, top: 12, child: _InviteBanner(onJoinChat: _open)),
      ]),
    );
  }

  Widget _tabPane(BuildContext context, ChatStore store, {required bool wide}) {
    return switch (_tab) {
      1 => FriendsPage(onOpenConversation: _open),
      2 => const MePage(),
      _ => ConversationList(
          activeId: wide ? _selected : null,
          onOpen: _open,
          onNew: _newChat,
          onSettings: () => setState(() => _tab = 2),
        ),
    };
  }

  Widget _navBar(BuildContext context, ChatStore store) {
    return NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      destinations: [
        NavigationDestination(
          icon: Badge(
            isLabelVisible: store.totalUnread > 0,
            label: Text(store.totalUnread > 99 ? '99+' : '${store.totalUnread}'),
            child: const Icon(Icons.chat_bubble_outline),
          ),
          selectedIcon: Badge(
            isLabelVisible: store.totalUnread > 0,
            label: Text(store.totalUnread > 99 ? '99+' : '${store.totalUnread}'),
            child: const Icon(Icons.chat_bubble),
          ),
          label: '消息',
        ),
        NavigationDestination(
          icon: Badge(
            isLabelVisible: store.pendingFriendCount > 0,
            label: Text(store.pendingFriendCount > 99 ? '99+' : '${store.pendingFriendCount}'),
            child: const Icon(Icons.people_outline),
          ),
          selectedIcon: Badge(
            isLabelVisible: store.pendingFriendCount > 0,
            label: Text(store.pendingFriendCount > 99 ? '99+' : '${store.pendingFriendCount}'),
            child: const Icon(Icons.people),
          ),
          label: '好友',
        ),
        const NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
      ],
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
      final sel = _selected;
      if (wide) {
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    NavigationRailDestination(
                      icon: Badge(
                        isLabelVisible: store.totalUnread > 0,
                        label: Text(store.totalUnread > 99 ? '99+' : '${store.totalUnread}'),
                        child: const Icon(Icons.chat_bubble_outline),
                      ),
                      selectedIcon: const Icon(Icons.chat_bubble),
                      label: const Text('消息'),
                    ),
                    NavigationRailDestination(
                      icon: Badge(
                        isLabelVisible: store.pendingFriendCount > 0,
                        label: Text(store.pendingFriendCount > 99 ? '99+' : '${store.pendingFriendCount}'),
                        child: const Icon(Icons.people_outline),
                      ),
                      selectedIcon: const Icon(Icons.people),
                      label: const Text('好友'),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.person_outline),
                      selectedIcon: Icon(Icons.person),
                      label: Text('我的'),
                    ),
                  ],
                ),
                VerticalDivider(width: 1, color: cs.outlineVariant),
                SizedBox(width: box.maxWidth >= 1200 ? 400 : 360, child: _tabPane(context, store, wide: true)),
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
      return Scaffold(
        body: SafeArea(child: _tabPane(context, store, wide: false)),
        bottomNavigationBar: _navBar(context, store),
      );
    });
  }
}

/// 群通话邀请横幅（group_call_started，60 秒自动收起由 Manager 计时）
class _InviteBanner extends StatelessWidget {
  const _InviteBanner({required this.onJoinChat});
  final void Function(int id) onJoinChat;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final gc = store.groupCalls;
    final inv = gc.invite;
    if (inv == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final conv = store.convs[inv.conversationId];
    final groupName = conv?.name.isNotEmpty == true ? conv!.name : '群聊';
    final creatorName = inv.creator != null ? store.displayOf(inv.creator) : '';
    return SafeArea(
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        color: cs.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            UserAvatar(user: inv.creator, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(
                  '$creatorName 在「$groupName」发起了${inv.isVideo ? '视频' : '语音'}通话',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
                ),
                Text('点加入进入通话', style: TextStyle(color: cs.onPrimaryContainer, fontSize: 12)),
              ]),
            ),
            TextButton(onPressed: gc.dismissInvite, child: const Text('忽略')),
            FilledButton(onPressed: () => gc.joinInvite(), child: const Text('加入')),
          ]),
        ),
      ),
    );
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
