import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../settings.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import 'avatar.dart';
import 'dialogs.dart';
import 'login_page.dart' show ServerPickerDialog;

const String _releasesUrl = 'https://github.com/fansa91/imchat-flutter/releases';
const String _appVersion = '0.5.0';

/// 「我的」页（SPEC v0.5.0 §2.2）：原 SettingsSheet 的内容整体迁入，
/// 分区为资料卡 / 账号安全 / 隐私 / 外观 / 服务器 / 存储 / 关于 / 退出登录。
class MePage extends StatefulWidget {
  const MePage({super.key});
  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  int? _cacheBytes;
  bool _cacheBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  Future<void> _refreshCache() async {
    final store = context.read<ChatStore>();
    final n = await store.cacheBytes();
    if (mounted) setState(() => _cacheBytes = n);
  }

  Future<void> _clearCache() async {
    final store = context.read<ChatStore>();
    setState(() => _cacheBusy = true);
    await store.clearCaches();
    if (!mounted) return;
    setState(() {
      _cacheBusy = false;
      _cacheBytes = 0;
    });
    store.showToast('缓存已清理');
  }

  Future<void> _pickServer() async {
    final settings = context.read<Settings>();
    final store = context.read<ChatStore>();
    final picked = await showDialog<String>(context: context, builder: (_) => const ServerPickerDialog());
    if (picked == null || picked == settings.server) return;
    // 切服务器即换账号上下文：先登出当前服务器，再切换（登录页会带出新服务器的令牌状态）
    await store.logout();
    await settings.setServer(picked);
  }

  Future<void> _revokeOthers() async {
    final store = context.read<ChatStore>();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出其他设备'),
        content: const Text('其他设备上的登录将全部失效，本设备保持登录。确定？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出其他设备')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await store.revokeOtherSessions();
    } catch (e) {
      store.showToast(e.toString());
    }
  }

  Future<void> _logout() async {
    final store = context.read<ChatStore>();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定退出当前账号？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (yes == true) await store.logout();
  }

  Future<void> _openReleases() async {
    final uri = Uri.parse(_releasesUrl);
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      // 打不开浏览器时退回展示可复制的链接
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('更新日志'),
          content: const SelectableText(_releasesUrl),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: _releasesUrl));
                Navigator.pop(ctx);
              },
              child: const Text('复制链接'),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final store = context.watch<ChatStore>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final me = store.me;
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(title, style: tt.titleSmall?.copyWith(color: cs.primary)),
        );
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('我的')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        // 资料卡
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: UserAvatar(user: me, size: 56),
          title: Text(displayName(me), style: tt.titleLarge),
          subtitle: Text([
            me?.email ?? '',
            'ID：${me?.id ?? ''}',
          ].join('\n')),
          isThreeLine: true,
          trailing: IconButton(
            tooltip: '复制用户 ID',
            icon: const Icon(Icons.copy_outlined),
            onPressed: me == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: '${me.id}'));
                    store.showToast('用户 ID 已复制');
                  },
          ),
          onTap: () => showDialog<void>(context: context, builder: (_) => const ProfileDialog()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('点资料卡可编辑头像与昵称', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
        section('账号安全'),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('修改密码'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDialog<void>(context: context, builder: (_) => const ChangePasswordDialog()),
        ),
        ListTile(
          leading: const Icon(Icons.devices_outlined),
          title: const Text('退出其他设备'),
          subtitle: const Text('让其他设备上的登录全部失效'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _revokeOthers,
        ),
        section('隐私'),
        SwitchListTile(
          secondary: const Icon(Icons.person_search_outlined),
          title: const Text('允许通过邮箱 / 用户 ID 找到我'),
          subtitle: const Text('关闭后，别人搜索你的邮箱或 ID 时会显示找不到；已是好友、已加入的群不受影响'),
          value: me?.allowFind ?? true,
          onChanged: (v) async {
            try {
              await store.updateAllowFind(v);
              store.showToast(v ? '已允许通过邮箱 / ID 找到你' : '已关闭，搜索将找不到你');
            } catch (e) {
              store.showToast(e.toString());
            }
          },
        ),
        section('外观'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.light, label: Text('浅色'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统'), icon: Icon(Icons.brightness_auto_outlined)),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (s) => settings.setThemeMode(s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('主题色', style: tt.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SeedPicker(value: settings.seed, onChanged: settings.setSeed),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            settings.seed == seedSystem
                ? '跟随系统壁纸 / 强调色（Material You）；系统不支持时使用默认紫色。'
                : 'Material 3 配色，由所选主题色生成。',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        section('服务器'),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('接口地址'),
          subtitle: Text(settings.server),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickServer,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('切换服务器将退出当前账号', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
        section('存储'),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('缓存占用'),
          subtitle: Text(_cacheBytes == null ? '计算中…' : fmtBytes(_cacheBytes!)),
          trailing: _cacheBusy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(onPressed: _clearCache, child: const Text('清理缓存')),
        ),
        section('关于'),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('版本'),
          subtitle: Text(_appVersion),
        ),
        ListTile(
          leading: const Icon(Icons.new_releases_outlined),
          title: const Text('更新日志'),
          subtitle: const Text('GitHub Release 页'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: _openReleases,
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
            onPressed: _logout,
          ),
        ),
      ]),
    );
  }
}
