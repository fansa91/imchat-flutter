import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store.dart';
import '../util.dart';
import 'avatar.dart';
import 'dialogs.dart' show errText;

/// 好友页（SPEC v0.5.0 §1.4）：新的朋友入口（带待处理红点）+ 好友列表
/// （备注优先显示、在线状态点）。点好友进详情页。
class FriendsPage extends StatelessWidget {
  const FriendsPage({super.key, required this.onOpenConversation});

  final void Function(int id) onOpenConversation;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // 显示名升序（备注优先规则）；中文按字符串排序，非拼音序
    final sorted = [...store.friends]..sort((a, b) => store.displayOf(a.user).compareTo(store.displayOf(b.user)));
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('好友'),
        actions: [
          IconButton(
            tooltip: '添加好友',
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AddFriendPage(onOpenConversation: onOpenConversation)),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await store.loadFriends().catchError((_) {});
          await store.loadFriendRequests().catchError((_) {});
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24, top: 4),
          children: [
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.person_add_alt_1, color: cs.onPrimaryContainer),
              ),
              title: const Text('新的朋友'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (store.pendingFriendCount > 0) ...[
                  Badge(
                    label: Text(store.pendingFriendCount > 99 ? '99+' : '${store.pendingFriendCount}'),
                    backgroundColor: cs.error,
                    textColor: cs.onError,
                  ),
                  const SizedBox(width: 4),
                ],
                const Icon(Icons.chevron_right),
              ]),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FriendRequestsPage()),
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('我的好友（${sorted.length}）', style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            if (sorted.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: Center(
                  child: Text('还没有好友，点右上角添加', style: TextStyle(color: cs.onSurfaceVariant)),
                ),
              ),
            for (final f in sorted)
              ListTile(
                leading: f.online
                    ? OnlineDot(size: 44, child: UserAvatar(user: f.user, size: 44))
                    : UserAvatar(user: f.user, size: 44),
                title: Text(store.displayOf(f.user), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: f.remark.isNotEmpty
                    ? Text('昵称：${f.user.nickname}', maxLines: 1, overflow: TextOverflow.ellipsis)
                    : (f.online ? const Text('在线') : null),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FriendDetailPage(userId: f.user.id, onOpenConversation: onOpenConversation),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 添加好友：邮箱 / 用户 ID 搜索 → 结果卡按 relation 渲染按钮（SPEC §1.3/§1.4）
class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key, required this.onOpenConversation});
  final void Function(int id) onOpenConversation;
  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

class _AddFriendPageState extends State<AddFriendPage> {
  final _input = TextEditingController();
  bool _byId = false;
  bool _busy = false;
  String _error = '';
  SearchResult? _result;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final raw = _input.text.trim();
    if (raw.isEmpty || _busy) return;
    final store = context.read<ChatStore>();
    setState(() {
      _busy = true;
      _error = '';
      _result = null;
    });
    try {
      SearchResult r;
      if (_byId) {
        final id = int.tryParse(raw);
        if (id == null || id <= 0) {
          setState(() => _error = '用户 ID 应为数字');
          return;
        }
        r = await store.searchUsers(id: id);
      } else {
        r = await store.searchUsers(email: raw);
      }
      if (r.user.id == store.me?.id) {
        setState(() => _error = '这是你自己');
        return;
      }
      setState(() => _result = r);
    } catch (e) {
      setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendRequest(SearchResult r) async {
    final store = context.read<ChatStore>();
    final msgCtrl = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('添加好友：${store.displayOf(r.user)}'),
        content: TextField(
          controller: msgCtrl,
          autofocus: true,
          maxLength: 128,
          decoration: const InputDecoration(labelText: '附言（可选）', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, msgCtrl.text), child: const Text('发送')),
        ],
      ),
    );
    msgCtrl.dispose();
    if (msg == null) return;
    setState(() => _busy = true);
    try {
      final status = await store.sendFriendRequest(r.user.id, msg);
      if (status == 'accepted') {
        store.showToast('已成为好友');
        setState(() => _result = SearchResult(user: r.user, relation: UserRelation.friend));
      } else {
        store.showToast('好友申请已发送');
        setState(() => _result = SearchResult(user: r.user, relation: UserRelation.pendingOut));
      }
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _acceptResult(SearchResult r) async {
    final store = context.read<ChatStore>();
    setState(() => _busy = true);
    try {
      // 找到对方发来的待处理申请并接受
      if (store.friendRequestsIn.isEmpty) await store.loadFriendRequests();
      final req = store.friendRequestsIn.where((x) => x.user.id == r.user.id).firstOrNull;
      if (req == null) {
        setState(() => _error = '申请已失效，请刷新后重试');
        await store.loadFriendRequests();
        return;
      }
      await store.acceptFriendRequest(req.id);
      store.showToast('已成为好友');
      setState(() => _result = SearchResult(user: r.user, relation: UserRelation.friend));
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _actionButton(SearchResult r) {
    final store = context.read<ChatStore>();
    return switch (r.relation) {
      UserRelation.friend => FilledButton.tonal(
          onPressed: _busy
              ? null
              : () async {
                  final cid = await store.startChatWithUser(r.user.id);
                  if (mounted) Navigator.pop(context);
                  widget.onOpenConversation(cid);
                },
          child: const Text('发消息'),
        ),
      UserRelation.pendingOut => const FilledButton.tonal(onPressed: null, child: Text('等待验证')),
      UserRelation.pendingIn => FilledButton(onPressed: _busy ? null : () => _acceptResult(r), child: const Text('接受')),
      UserRelation.none => FilledButton(onPressed: _busy ? null : () => _sendRequest(r), child: const Text('添加')),
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('添加好友')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('邮箱'), icon: Icon(Icons.mail_outline)),
            ButtonSegment(value: true, label: Text('用户 ID'), icon: Icon(Icons.numbers)),
          ],
          selected: {_byId},
          onSelectionChanged: (s) => setState(() {
            _byId = s.first;
            _error = '';
            _result = null;
          }),
        ),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: _input,
              autofocus: true,
              keyboardType: _byId ? TextInputType.number : TextInputType.emailAddress,
              inputFormatters: _byId ? [FilteringTextInputFormatter.digitsOnly] : null,
              onSubmitted: (_) => _search(),
              onChanged: (_) => _error.isEmpty ? null : setState(() => _error = ''),
              decoration: InputDecoration(
                labelText: _byId ? '对方用户 ID' : '对方邮箱',
                border: const OutlineInputBorder(),
                errorText: _error.isEmpty ? null : _error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton(onPressed: _busy ? null : _search, child: const Text('搜索')),
          ),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 24), child: Center(child: CircularProgressIndicator())),
        if (r != null) ...[
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                UserAvatar(user: r.user, size: 56),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(store.displayOf(r.user),
                        style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('ID：${r.user.id}', style: TextStyle(color: cs.onSurfaceVariant)),
                    if (r.relation == UserRelation.friend && r.user.nickname.isNotEmpty)
                      Text('昵称：${r.user.nickname}', style: TextStyle(color: cs.onSurfaceVariant)),
                  ]),
                ),
                _actionButton(r),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

/// 好友申请列表：收到的（接受 / 拒绝）与我发出的（可撤回）
class FriendRequestsPage extends StatelessWidget {
  const FriendRequestsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget section(String title, List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(title, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            ...children,
          ],
        );
    return Scaffold(
      appBar: AppBar(title: const Text('新的朋友')),
      body: RefreshIndicator(
        onRefresh: () => store.loadFriendRequests().catchError((_) {}),
        child: ListView(children: [
          if (store.friendRequestsIn.isEmpty && store.friendRequestsOut.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 64),
              child: Center(child: Text('暂无好友申请', style: TextStyle(color: cs.onSurfaceVariant))),
            ),
          if (store.friendRequestsIn.isNotEmpty)
            section('收到的申请', [
              for (final r in store.friendRequestsIn)
                ListTile(
                  leading: UserAvatar(user: r.user),
                  title: Text(store.displayOf(r.user)),
                  subtitle: Text(
                    [if (r.message.isNotEmpty) r.message, if (r.createdAt != null) listTime(r.createdAt!)].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    TextButton(
                      onPressed: () async {
                        try {
                          await store.rejectFriendRequest(r.id);
                        } catch (e) {
                          store.showToast(errText(e));
                        }
                      },
                      child: const Text('拒绝'),
                    ),
                    FilledButton(
                      onPressed: () async {
                        try {
                          await store.acceptFriendRequest(r.id);
                          store.showToast('已成为好友');
                        } catch (e) {
                          store.showToast(errText(e));
                        }
                      },
                      child: const Text('接受'),
                    ),
                  ]),
                ),
            ]),
          if (store.friendRequestsOut.isNotEmpty)
            section('我发出的申请', [
              for (final r in store.friendRequestsOut)
                ListTile(
                  leading: UserAvatar(user: r.user),
                  title: Text(store.displayOf(r.user)),
                  subtitle: Text(
                    [if (r.message.isNotEmpty) r.message, '等待验证'].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await store.cancelFriendRequest(r.id);
                      } catch (e) {
                        store.showToast(errText(e));
                      }
                    },
                    child: const Text('撤回'),
                  ),
                ),
            ]),
        ]),
      ),
    );
  }
}

/// 好友详情：设置备注 / 发消息 / 1 对 1 通话 / 拉进群 / 删除好友
class FriendDetailPage extends StatelessWidget {
  const FriendDetailPage({super.key, required this.userId, required this.onOpenConversation});

  final int userId;
  final void Function(int id) onOpenConversation;

  Future<void> _editRemark(BuildContext context) async {
    final store = context.read<ChatStore>();
    final f = store.friendOf(userId);
    final ctrl = TextEditingController(text: f?.remark ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置备注'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: '备注名（仅自己可见）', border: OutlineInputBorder()),
          onSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('保存')),
        ],
      ),
    );
    ctrl.dispose();
    if (v == null) return;
    try {
      await store.setFriendRemark(userId, v);
      store.showToast(v.trim().isEmpty ? '已清除备注' : '备注已保存');
    } catch (e) {
      store.showToast(errText(e));
    }
  }

  Future<void> _openChat(BuildContext context) async {
    final store = context.read<ChatStore>();
    try {
      final cid = await store.startChatWithUser(userId);
      if (context.mounted) Navigator.pop(context);
      onOpenConversation(cid);
    } catch (e) {
      store.showToast(errText(e));
    }
  }

  Future<void> _call(BuildContext context, String kind) async {
    final store = context.read<ChatStore>();
    try {
      final cid = await store.startChatWithUser(userId);
      if (context.mounted) Navigator.pop(context);
      onOpenConversation(cid);
      await store.calls.startCall(cid, kind);
    } catch (e) {
      store.showToast(errText(e));
    }
  }

  Future<void> _inviteToGroup(BuildContext context) async {
    final store = context.read<ChatStore>();
    final groups = store.sortedConversations.where((c) => c.isGroup).toList();
    if (groups.isEmpty) {
      store.showToast('你还没有群聊');
      return;
    }
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('拉进群聊'),
        content: SizedBox(
          width: 360,
          child: ListView(shrinkWrap: true, children: [
            for (final g in groups)
              ListTile(
                leading: ConvAvatar(conv: g),
                title: Text(convTitle(g, store.friendRemarks)),
                subtitle: Text('${g.memberCount} 位成员'),
                onTap: () => Navigator.pop(ctx, g.id),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))],
      ),
    );
    if (picked == null) return;
    try {
      await store.addMembers(picked, [userId]);
      store.showToast('已邀请进群');
    } catch (e) {
      store.showToast(errText(e));
    }
  }

  Future<void> _delete(BuildContext context) async {
    final store = context.read<ChatStore>();
    final nav = Navigator.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除好友：${store.displayOf(store.users[userId])}'),
        content: const Text('删除后你们将不再是好友。聊天记录不会删除，原单聊会话仍可继续使用。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await store.removeFriend(userId);
      store.showToast('已删除好友');
      nav.pop();
    } catch (e) {
      store.showToast(errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final f = store.friendOf(userId);
    final user = f?.user ?? store.users[userId];
    if (user == null) {
      return Scaffold(appBar: AppBar(title: const Text('好友详情')), body: const Center(child: Text('用户不存在')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('好友详情')),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        const SizedBox(height: 24),
        Center(
          child: f != null && f.online
              ? OnlineDot(size: 88, child: UserAvatar(user: user, size: 88))
              : UserAvatar(user: user, size: 88),
        ),
        const SizedBox(height: 12),
        Center(child: Text(store.displayOf(user), style: tt.titleLarge)),
        const SizedBox(height: 4),
        Center(
          child: Text(
            [
              if (f != null && f.remark.isNotEmpty) '昵称：${user.nickname}',
              'ID：${user.id}',
              if (f != null) (f.online ? '在线' : '离线'),
            ].join(' · '),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 24),
        if (f != null) ...[
          ListTile(
            leading: const Icon(Icons.edit_note_outlined),
            title: const Text('设置备注'),
            subtitle: Text(f.remark.isEmpty ? '未设置' : f.remark),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editRemark(context),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('发消息'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openChat(context),
          ),
          if (store.config.callEnabled) ...[
            ListTile(
              leading: const Icon(Icons.call_outlined),
              title: const Text('语音通话'),
              onTap: () => _call(context, 'audio'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('视频通话'),
              onTap: () => _call(context, 'video'),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.group_add_outlined),
            title: const Text('拉进群聊'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _inviteToGroup(context),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.person_remove_outlined, color: cs.error),
            title: Text('删除好友', style: TextStyle(color: cs.error)),
            onTap: () => _delete(context),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: Text('你们还不是好友', style: TextStyle(color: cs.onSurfaceVariant))),
          ),
      ]),
    );
  }
}
