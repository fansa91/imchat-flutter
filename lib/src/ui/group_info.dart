import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store.dart';
import '../util.dart';
import 'avatar.dart';
import 'dialogs.dart';

const _roleName = ['', '管理员', '群主'];

/// 群聊信息：群名、公告、成员列表（添加 / 移除 / 设管理员）、退出群聊。
/// 窄屏全屏页面，宽屏对话框。
Future<void> showGroupInfo(BuildContext context, int id) {
  final wide = MediaQuery.sizeOf(context).width >= 840;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
          child: GroupInfoPage(id: id),
        ),
      ),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupInfoPage(id: id)));
}

class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({super.key, required this.id});
  final int id;
  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  final _email = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    context.read<ChatStore>().loadMembers(widget.id);
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<bool> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
      return true;
    } catch (e) {
      if (mounted) context.read<ChatStore>().showToast(errText(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _prompt({required String title, required String label, String initial = '', int maxLength = 32, int maxLines = 1}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLength: maxLength,
            maxLines: maxLines,
            minLines: 1,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('保存')),
        ],
      ),
    );
  }

  Future<void> _addMember() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    final store = context.read<ChatStore>();
    final ok = await _run(() async {
      final u = await store.findUser(email);
      await store.addMembers(widget.id, [u.id]);
    });
    if (ok) _email.clear();
  }

  Future<void> _leave(int myRole) async {
    final store = context.read<ChatStore>();
    final nav = Navigator.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出群聊'),
        content: Text(myRole == roleOwner ? '退出后群主将转给其他成员，确定？' : '确定退出群聊？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (yes != true) return;
    if (await _run(() => store.leaveGroup(widget.id))) nav.pop();
  }

  void _memberActions(Member m, int myRole) {
    final store = context.read<ChatStore>();
    final canRemove = myRole >= roleAdmin && m.role < myRole;
    final canRole = myRole == roleOwner;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: UserAvatar(user: m.user),
            title: Text(store.displayOf(m.user)),
            subtitle: Text(m.user.email),
          ),
          if (canRole)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(m.role == roleAdmin ? '取消管理员' : '设为管理员'),
              onTap: () {
                Navigator.pop(ctx);
                _run(() => store.setRole(widget.id, m.user.id, m.role == roleAdmin ? 'member' : 'admin'));
              },
            ),
          if (canRemove)
            ListTile(
              leading: Icon(Icons.person_remove_outlined, color: Theme.of(ctx).colorScheme.error),
              title: Text('移出群聊', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _run(() => store.removeMember(widget.id, m.user.id));
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final conv = store.convs[widget.id];
    if (conv == null) {
      return Scaffold(appBar: AppBar(title: const Text('群聊信息')), body: const Center(child: Text('已不在该群聊中')));
    }
    final members = store.members[widget.id] ?? const <Member>[];
    final meId = store.me?.id;
    final myRole = members.where((m) => m.user.id == meId).firstOrNull?.role ?? conv.myRole;
    final sorted = [...members]..sort((a, b) => b.role.compareTo(a.role));

    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊信息'),
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SizedBox(height: 8),
          Center(child: ConvAvatar(conv: conv, size: 72)),
          const SizedBox(height: 8),
          Center(child: Text(convTitle(conv, store.friendRemarks), style: tt.titleLarge)),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('群名称'),
            subtitle: Text(conv.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy
                ? null
                : () async {
                    final v = await _prompt(title: '修改群名称', label: '群名称', initial: conv.name);
                    if (v != null && v.trim().isNotEmpty) await _run(() => store.renameGroup(widget.id, v.trim()));
                  },
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('群公告'),
            subtitle: Text(
              conv.announcement.isEmpty
                  ? '暂无公告'
                  : '${conv.announcement}${conv.announcementAt != null ? '\n更新于 ${listTime(conv.announcementAt!)}' : ''}',
            ),
            isThreeLine: conv.announcement.isNotEmpty,
            trailing: myRole >= roleAdmin ? const Icon(Icons.chevron_right) : null,
            onTap: myRole >= roleAdmin && !_busy
                ? () async {
                    final v = await _prompt(
                      title: '编辑群公告',
                      label: '群公告（只有群主和管理员可以修改）',
                      initial: conv.announcement,
                      maxLength: 1000,
                      maxLines: 6,
                    );
                    if (v != null) await _run(() => store.setAnnouncement(widget.id, v.trim()));
                  }
                : null,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '成员（${members.isNotEmpty ? members.length : conv.memberCount}/${store.config.groupMaxMembers}）',
              style: tt.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: (_) => _addMember(),
                  decoration: const InputDecoration(
                    labelText: '添加成员（邮箱）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: _busy ? null : _addMember, child: const Text('添加')),
            ]),
          ),
          for (final m in sorted)
            ListTile(
              leading: store.config.presenceEnabled && store.isOnline(m.user.id)
                  ? OnlineDot(size: 40, child: UserAvatar(user: m.user))
                  : UserAvatar(user: m.user),
              title: Row(children: [
                Flexible(child: Text(m.user.id == meId ? '${store.displayOf(m.user)}（我）' : store.displayOf(m.user), overflow: TextOverflow.ellipsis)),
                if (m.role > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: m.role == roleOwner ? cs.tertiaryContainer : cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(_roleName[m.role.clamp(0, 2)], style: tt.labelSmall),
                  ),
                ],
              ]),
              subtitle: Text(m.user.email, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: m.user.id != meId && (myRole == roleOwner || (myRole >= roleAdmin && m.role < myRole))
                  ? const Icon(Icons.more_vert)
                  : null,
              onTap: m.user.id != meId && (myRole == roleOwner || (myRole >= roleAdmin && m.role < myRole))
                  ? () => _memberActions(m, myRole)
                  : null,
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: cs.error),
              icon: const Icon(Icons.logout),
              label: const Text('退出群聊'),
              onPressed: _busy ? null : () => _leave(myRole),
            ),
          ),
        ],
      ),
    );
  }
}
