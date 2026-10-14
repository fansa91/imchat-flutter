import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../settings.dart';
import '../store.dart';

/// 登录 / 注册，带服务器地址选择（默认 + 历史列表 + 自定义）
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _register = false;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _nickname = TextEditingController();
  String _error = '';
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入邮箱和密码');
      return;
    }
    if (_register && password.length < 8) {
      setState(() => _error = '密码至少 8 位');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await context.read<ChatStore>().login(email, password, register: _register, nickname: _nickname.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '出错了：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickServer() async {
    final picked = await showDialog<String>(context: context, builder: (_) => const ServerPickerDialog());
    if (picked != null && mounted) await context.read<Settings>().setServer(picked);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.forum_rounded, size: 64, color: cs.primary),
                    const SizedBox(height: 12),
                    Text('IMChat', textAlign: TextAlign.center, style: tt.headlineMedium),
                    const SizedBox(height: 4),
                    Text(_register ? '创建新账号' : '登录以继续',
                        textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 24),
                    Card.outlined(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.dns_outlined),
                        title: const Text('服务器'),
                        subtitle: Text(settings.server, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.expand_more),
                        onTap: _busy ? null : _pickServer,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('登录'), icon: Icon(Icons.login)),
                        ButtonSegment(value: true, label: Text('注册'), icon: Icon(Icons.person_add_alt)),
                      ],
                      selected: {_register},
                      onSelectionChanged: (s) => setState(() {
                        _register = s.first;
                        _error = '';
                      }),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email, AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '邮箱',
                        prefixIcon: Icon(Icons.alternate_email),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_register) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nickname,
                        maxLength: 32,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.nickname],
                        decoration: const InputDecoration(
                          labelText: '昵称（可选）',
                          prefixIcon: Icon(Icons.badge_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: _obscure,
                      autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: _register ? '密码（8~72 位）' : '密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscure ? '显示密码' : '隐藏密码',
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(_error, style: TextStyle(color: cs.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_register ? '注册并登录' : '登录'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 服务器地址选择：已保存的列表 + 自定义输入
class ServerPickerDialog extends StatefulWidget {
  const ServerPickerDialog({super.key});
  @override
  State<ServerPickerDialog> createState() => _ServerPickerDialogState();
}

class _ServerPickerDialogState extends State<ServerPickerDialog> {
  final _custom = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _useCustom() {
    final s = normalizeServer(_custom.text);
    final uri = Uri.tryParse(s);
    if (s.isEmpty || uri == null || uri.host.isEmpty) {
      setState(() => _error = '请输入有效的地址，例如 https://im.example.com');
      return;
    }
    Navigator.pop(context, s);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    return AlertDialog(
      title: const Text('选择服务器'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioGroup<String>(
                groupValue: settings.server,
                onChanged: (v) => Navigator.pop(context, v),
                child: Column(
                  children: [
                    for (final s in settings.servers)
                      RadioListTile<String>(
                        value: s,
                        title: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: s == defaultServer ? const Text('默认') : null,
                        secondary: s == defaultServer
                            ? null
                            : IconButton(
                                tooltip: '移除',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => settings.removeServer(s),
                              ),
                      ),
                  ],
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: TextField(
                  controller: _custom,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _useCustom(),
                  decoration: InputDecoration(
                    labelText: '自定义服务器地址',
                    hintText: 'https://im.example.com',
                    border: const OutlineInputBorder(),
                    errorText: _error.isEmpty ? null : _error,
                    suffixIcon: IconButton(
                      tooltip: '使用此地址',
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: _useCustom,
                    ),
                  ),
                  onChanged: (_) => _error.isEmpty ? null : setState(() => _error = ''),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    );
  }
}
