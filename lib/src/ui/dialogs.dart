import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../settings.dart';
import '../store.dart';
import '../util.dart';
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
                    label: Text(displayName(u)),
                    onDeleted: () => setState(() => _picked.removeWhere((p) => p.id == u.id)),
                  ),
              ]),
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

/// 主题与账号
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final store = context.read<ChatStore>();
    final me = store.me;
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: UserAvatar(user: me, size: 48),
            title: Text(displayName(me), style: tt.titleMedium),
            subtitle: Text('${me?.email ?? ''}\n${settings.server}'),
            isThreeLine: true,
          ),
          const SizedBox(height: 8),
          Text('主题', style: tt.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.light, label: Text('浅色'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统'), icon: Icon(Icons.brightness_auto_outlined)),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (s) => settings.setThemeMode(s.first),
          ),
          const SizedBox(height: 8),
          Text('配色跟随系统壁纸（Material You）；系统不支持时使用默认配色。',
              style: tt.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
            onPressed: () {
              Navigator.pop(context);
              store.logout();
            },
          ),
        ]),
      ),
    );
  }
}
