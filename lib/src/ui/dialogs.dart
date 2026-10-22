import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'avatar.dart';

String errText(Object e) => e is ApiError && e.status == 404
    ? '没有找到这个用户'
    : e is ApiError
        ? e.message
        : '出错了';

/// 发起聊天：单聊（对方邮箱）/ 群聊（群名 + 逐个添加成员邮箱）。返回会话 ID。
class NewChatDialog extends StatefulWidget {
  const NewChatDialog({super.key});
  @override
  State<NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<NewChatDialog> {
  bool _group = false;
  final _email = TextEditingController();
  final _name = TextEditingController();
  final List<User> _picked = [];
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _addPerson() async {
    final store = context.read<ChatStore>();
    if (_email.text.trim().isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final u = await store.findUser(_email.text);
      if (u.id == store.me?.id) {
        _error = '不用添加自己';
      } else if (!_picked.any((p) => p.id == u.id)) {
        _picked.add(u);
      }
      _email.clear();
    } catch (e) {
      _error = errText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 单聊模式点好友直接开聊（v0.5.0 好友快捷入口）
  Future<void> _chatWithFriend(User u) async {
    if (_busy) return;
    final store = context.read<ChatStore>();
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final id = await store.startChatWithUser(u.id);
      nav.pop(id);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _submit() async {
    if (_busy) return;
    final store = context.read<ChatStore>();
    final nav = Navigator.of(context);
    if (_group) {
      if (_email.text.trim().isNotEmpty) return _addPerson();
      if (_picked.isEmpty) {
        setState(() => _error = '至少添加 1 位成员');
        return;
      }
      setState(() {
        _busy = true;
        _error = '';
      });
      try {
        final id = await store.createGroup(_name.text.trim(), _picked.map((u) => u.id).toList());
        nav.pop(id);
      } catch (e) {
        if (mounted) setState(() => _error = errText(e));
      }
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (_email.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final id = await store.startChatByEmail(_email.text);
      nav.pop(id);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_group ? '发起群聊' : '发起聊天'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('单聊'), icon: Icon(Icons.person_outline)),
                ButtonSegment(value: true, label: Text('群聊'), icon: Icon(Icons.group_outlined)),
              ],
              selected: {_group},
              onSelectionChanged: (s) => setState(() {
                _group = s.first;
                _error = '';
              }),
            ),
            const SizedBox(height: 16),
            if (_group) ...[
              TextField(
                controller: _name,
                maxLength: 32,
                decoration: const InputDecoration(labelText: '群名称（可选）', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 4),
            ],
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _email,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: (_) => _group ? _addPerson() : _submit(),
                  onChanged: (_) => _error.isEmpty ? null : setState(() => _error = ''),
                  decoration: InputDecoration(
                    labelText: _group ? '添加成员（邮箱）' : '对方邮箱',
                    border: const OutlineInputBorder(),
                    errorText: _error.isEmpty ? null : _error,
                  ),
                ),
              ),
              if (_group) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.tonal(onPressed: _busy ? null : _addPerson, child: const Text('添加')),
                ),
              ],
            ]),
            if (_group && _picked.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final u in _picked)
                  InputChip(
                    avatar: UserAvatar(user: u, size: 24),
                    label: Text(context.read<ChatStore>().displayOf(u)),
                    onDeleted: () => setState(() => _picked.removeWhere((p) => p.id == u.id)),
                  ),
              ]),
            ],
            // v0.5.0：好友快捷选择（建群选人时好友置顶；单聊点好友直接开聊）
            if (context.watch<ChatStore>().friends.isNotEmpty) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('我的好友', style: Theme.of(context).textTheme.titleSmall),
              ),
              const SizedBox(height: 4),
              if (_group)
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final f in context.watch<ChatStore>().friends)
                    if (!_picked.any((p) => p.id == f.user.id))
                      ActionChip(
                        avatar: UserAvatar(user: f.user, size: 24),
                        label: Text(context.read<ChatStore>().displayOf(f.user)),
                        onPressed: _busy ? null : () => setState(() => _picked.add(f.user)),
                      ),
                ])
              else
                for (final f in context.watch<ChatStore>().friends)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: UserAvatar(user: f.user, size: 36),
                    title: Text(context.read<ChatStore>().displayOf(f.user)),
                    subtitle: f.online ? const Text('在线') : null,
                    onTap: _busy ? null : () => _chatWithFriend(f.user),
                  ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_group ? '创建群聊' : '开始聊天'),
        ),
      ],
    );
  }
}

/// 编辑资料：头像（选图裁正方形 512 后直传）与昵称（SPEC v0.4.0 §3）
class ProfileDialog extends StatefulWidget {
  const ProfileDialog({super.key});
  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  late final TextEditingController _nick =
      TextEditingController(text: context.read<ChatStore>().me?.nickname ?? '');
  String _error = '';
  bool _busy = false;
  bool _avatarBusy = false;

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final store = context.read<ChatStore>();
    XFile? xf;
    try {
      xf = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (_) {
      store.showToast('无法打开图片选择');
      return;
    }
    if (xf == null) return;
    setState(() => _avatarBusy = true);
    try {
      final bytes = await xf.readAsBytes();
      await store.updateAvatar(bytes);
      store.showToast('头像已更新');
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiError && e.status == 404 ? '服务端不支持修改资料' : errText(e));
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _save() async {
    final store = context.read<ChatStore>();
    final nick = _nick.text.trim();
    if (nick.isEmpty) {
      setState(() => _error = '昵称不能为空');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await store.updateNickname(nick);
      if (mounted) Navigator.pop(context);
      store.showToast('资料已更新');
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ApiError && e.status == 404 ? '服务端不支持修改资料' : errText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<ChatStore>().me;
    return AlertDialog(
      title: const Text('编辑资料'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: _avatarBusy ? null : _pickAvatar,
            child: Stack(alignment: Alignment.bottomRight, children: [
              UserAvatar(user: me, size: 84),
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
                child: _avatarBusy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.camera_alt, size: 14, color: Colors.white),
              ),
            ]),
          ),
          const SizedBox(height: 6),
          Text('点击更换头像', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          TextField(
            controller: _nick,
            maxLength: 64,
            decoration: InputDecoration(
              labelText: '昵称',
              border: const OutlineInputBorder(),
              errorText: _error.isEmpty ? null : _error,
            ),
            onChanged: (_) => _error.isEmpty ? null : setState(() => _error = ''),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
      ],
    );
  }
}

/// 修改密码（SPEC v0.4.0 §4.4）：成功后当前设备换新 token 无感续用
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key});
  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final store = context.read<ChatStore>();
    if (_new.text.length < 8 || _new.text.length > 72) {
      setState(() => _error = '新密码需为 8~72 位');
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await store.changePassword(_old.text, _new.text);
      if (mounted) Navigator.pop(context);
      store.showToast('密码已修改，其他设备已退出登录');
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ApiError ? e.message : '修改失败';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改密码'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _old,
            obscureText: true,
            decoration: const InputDecoration(labelText: '当前密码', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _new,
            obscureText: true,
            decoration: const InputDecoration(labelText: '新密码（8~72 位）', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '确认新密码',
              border: const OutlineInputBorder(),
              errorText: _error.isEmpty ? null : _error,
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('修改')),
      ],
    );
  }
}

/// 主题色选择：跟随系统 + 8 个种子色（与网页端相同）；v0.5.0 起在「我的」页使用
class SeedPicker extends StatelessWidget {
  const SeedPicker({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = parseSeed(value);
    Widget swatch({required bool active, required String label, required VoidCallback onTap, required Widget child}) =>
        Semantics(
          button: true,
          selected: active,
          label: label,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: 40,
              height: 40,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: active ? cs.onSurface : Colors.transparent, width: 2),
              ),
              child: child,
            ),
          ),
        );

    return Wrap(spacing: 8, runSpacing: 8, children: [
      swatch(
        active: selected == null,
        label: '跟随系统',
        onTap: () => onChanged(seedSystem),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: [...themeSeeds, themeSeeds.first]),
          ),
          child: Icon(Icons.auto_awesome, size: 16, color: selected == null ? Colors.white : Colors.white70),
        ),
      ),
      for (final c in themeSeeds)
        swatch(
          active: selected?.toARGB32() == c.toARGB32(),
          label: seedToString(c),
          onTap: () => onChanged(seedToString(c)),
          child: Container(
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            child: selected?.toARGB32() == c.toARGB32() ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
          ),
        ),
    ]);
  }
}
