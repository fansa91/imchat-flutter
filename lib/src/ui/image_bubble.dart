import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as pathlib;
import 'package:provider/provider.dart';

import '../models.dart';
import '../store.dart';

/// 图片气泡：按原图比例预留占位（最大 260x320），本地有文件后显示；点击全屏查看。
///
/// 注意：这里只处理 onTap，长按 / 右键交给外层 MessageItem 的 GestureDetector 弹出消息菜单。
class ImageBubble extends StatelessWidget {
  const ImageBubble({super.key, required this.m, required this.mine});
  final Message m;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    store.ensureImage(m);
    final state = context.select<ChatStore, MediaState?>((s) => s.imageState(m));
    final ic = ImageContent.of(m);
    final (w, h) = imageBubbleSize(ic?.width ?? 0, ic?.height ?? 0);
    final file = state == MediaState.ready ? store.imageFileSync(m) : null;
    final cs = Theme.of(context).colorScheme;
    final fg = mine ? cs.onPrimary : cs.onSurfaceVariant;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tag = heroTagOf(m);

    Widget placeholder(Widget child) => Container(
          width: w,
          height: h,
          color: mine ? cs.primary : cs.surfaceContainerHighest,
          alignment: Alignment.center,
          child: child,
        );

    Widget body;
    if (file != null) {
      body = Hero(
        tag: tag,
        child: Image.file(
          file,
          width: w,
          height: h,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: (w * dpr).round(),
          errorBuilder: (_, _, _) => placeholder(Icon(Icons.broken_image_outlined, color: fg)),
        ),
      );
    } else {
      body = switch (state) {
        MediaState.expired => placeholder(Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.hide_image_outlined, color: fg),
            const SizedBox(height: 4),
            Text('图片已过期', style: TextStyle(color: fg, fontSize: 12)),
          ])),
        MediaState.error => placeholder(Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.refresh, color: fg),
            const SizedBox(height: 4),
            Text('加载失败，点击重试', style: TextStyle(color: fg, fontSize: 12)),
          ])),
        _ => placeholder(SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: fg))),
      };
    }

    final uploading = m.seq == 0 && m.status == MsgStatus.sending;
    return GestureDetector(
      onTap: () async {
        if (state == MediaState.error) return store.retryImage(m);
        if (file == null) return;
        await openImageViewer(context, file, tag: tag, name: suggestedImageName(m, file));
      },
      child: Stack(alignment: Alignment.center, children: [
        body,
        if (uploading)
          Container(
            width: 36,
            height: 36,
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
            child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
      ]),
    );
  }
}

String heroTagOf(Message m) => 'img:${m.conversationId}:${m.seq > 0 ? m.seq : m.clientMsgId}';

String suggestedImageName(Message m, File f) {
  final ext = pathlib.extension(f.path).isEmpty ? '.jpg' : pathlib.extension(f.path);
  return 'IMChat_${m.conversationId}_${m.seq > 0 ? m.seq : DateTime.now().millisecondsSinceEpoch}$ext';
}

Future<void> openImageViewer(BuildContext context, File file, {required String tag, required String name}) =>
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => ImageViewerPage(file: file, tag: tag, name: name),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));

/// 保存图片：移动端存到系统相册，桌面端弹出“另存为”。返回提示文字，用户取消返回 null。
Future<String?> saveImage(File file, String name) async {
  if (Platform.isAndroid || Platform.isIOS) {
    if (!await Gal.hasAccess()) {
      if (!await Gal.requestAccess()) return '没有相册权限';
    }
    await Gal.putImage(file.path);
    return '已保存到相册';
  }
  final ext = pathlib.extension(name).replaceFirst('.', '');
  final loc = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(label: '图片', extensions: [if (ext.isNotEmpty) ext]),
    ],
  );
  if (loc == null) return null;
  await file.copy(loc.path);
  return '已保存';
}

/// 全屏查看：双指 / 滚轮缩放、拖动，右上角保存
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.file, required this.tag, required this.name});
  final File file;
  final String tag;
  final String name;

  Future<void> _save(BuildContext context) async {
    final store = context.read<ChatStore>();
    try {
      final msg = await saveImage(file, name);
      if (msg != null) store.showToast(msg);
    } catch (e) {
      store.showToast('保存失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context)},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.black38,
            foregroundColor: Colors.white,
            leading: IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                tooltip: Platform.isAndroid || Platform.isIOS ? '保存到相册' : '另存为',
                icon: const Icon(Icons.download),
                onPressed: () => _save(context),
              ),
            ],
          ),
          body: InteractiveViewer(
            minScale: 1,
            maxScale: 6,
            child: SizedBox.expand(
              child: Hero(
                tag: tag,
                child: Image.file(file, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
