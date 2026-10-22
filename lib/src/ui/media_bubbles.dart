import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../recorder.dart' show fmtDuration;
import '../store.dart';
import '../util.dart';

/// 视频气泡（SPEC v0.4.0 §2.4）：按宽高预留比例占位，封面区显示播放角标与时长；
/// 点击后才下载到本地缓存并全屏播放（不自动下载，避免大文件流量）。
///
/// 说明：poster_key 引用的封面对象服务端没有独立的取图接口，气泡层用占位 +
/// 播放角标呈现；真正首帧在播放页由 video_player 呈现。
class VideoBubble extends StatefulWidget {
  const VideoBubble({super.key, required this.m, required this.mine});
  final Message m;
  final bool mine;

  @override
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  bool _busy = false;

  Future<void> _open() async {
    final store = context.read<ChatStore>();
    final m = widget.m;
    if (m.seq == 0 || _busy) return;
    setState(() => _busy = true);
    try {
      final f = await store.mediaFile(m);
      if (!mounted) return;
      if (f == null) {
        store.showToast('视频下载失败');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoPlayerPage(file: f)));
    } catch (e) {
      store.showToast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final m = widget.m;
    final vc = VideoContent.of(m);
    final (w, h) = imageBubbleSize(vc?.width ?? 0, vc?.height ?? 0);
    final cs = Theme.of(context).colorScheme;
    final progress = m.seq == 0 ? store.uploadProgress[m.clientMsgId] : null;
    final cached = m.seq > 0 && store.mediaFileSync(m) != null;
    return GestureDetector(
      onTap: _open,
      child: Container(
        width: w,
        height: h,
        color: Colors.black87,
        child: Stack(alignment: Alignment.center, children: [
          Icon(Icons.movie_outlined, size: 44, color: Colors.white24),
          if (_busy || progress != null)
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white,
                value: progress,
              ),
            )
          else
            Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: Icon(cached || m.seq == 0 ? Icons.play_arrow : Icons.download, color: Colors.white, size: 30),
            ),
          Positioned(
            right: 8,
            bottom: 6,
            child: Text(
              fmtDuration(vc?.durationMs ?? 0),
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          if (vc != null && vc.size > 0)
            Positioned(
              left: 8,
              bottom: 6,
              child: Text(fmtBytes(vc.size), style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ),
          Positioned(
            top: 6,
            right: 8,
            child: Icon(Icons.videocam_outlined, size: 16, color: cs.onInverseSurface.withValues(alpha: 0.7)),
          ),
        ]),
      ),
    );
  }
}

/// 文件气泡：图标（按扩展名）+ 文件名 + 大小；点击下载到本地缓存后提示路径。
class FileBubble extends StatefulWidget {
  const FileBubble({super.key, required this.m, required this.mine});
  final Message m;
  final bool mine;

  @override
  State<FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<FileBubble> {
  bool _busy = false;

  static IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' || 'txt' || 'md' => Icons.description_outlined,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
      'ppt' || 'pptx' => Icons.slideshow_outlined,
      'zip' || 'rar' || '7z' || 'gz' => Icons.folder_zip_outlined,
      'mp3' || 'm4a' || 'wav' || 'ogg' => Icons.audio_file_outlined,
      'mp4' || 'mov' || 'webm' => Icons.video_file_outlined,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Future<void> _open() async {
    final store = context.read<ChatStore>();
    final m = widget.m;
    if (m.seq == 0 || _busy) return;
    final have = store.mediaFileSync(m);
    if (have != null) {
      store.showToast('已下载：${have.path}');
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await store.mediaFile(m);
      if (f != null) store.showToast('已保存到 ${f.path}');
    } catch (e) {
      store.showToast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final m = widget.m;
    final fc = FileContent.of(m);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final fg = widget.mine ? cs.onPrimary : cs.onSurface;
    final sub = widget.mine ? cs.onPrimary.withValues(alpha: 0.75) : cs.onSurfaceVariant;
    final progress = m.seq == 0 ? store.uploadProgress[m.clientMsgId] : null;
    final name = fc?.name ?? '文件';
    return GestureDetector(
      onTap: _open,
      child: Container(
        width: 232,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          if (_busy || progress != null)
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 2.5, value: progress, color: fg),
            )
          else
            Icon(_iconFor(name), size: 36, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.bodyMedium?.copyWith(color: fg)),
              const SizedBox(height: 2),
              Text(
                progress != null
                    ? '上传中 ${(progress * 100).round()}%'
                    : _busy
                        ? '下载中…'
                        : fmtBytes(fc?.size ?? 0),
                style: tt.bodySmall?.copyWith(color: sub),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 全屏视频播放页（video_player，本地缓存文件）
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.file});
  final File file;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerController _ctl = VideoPlayerController.file(widget.file);
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _ctl.play();
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '无法播放该视频');
    });
    _ctl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black38,
        foregroundColor: Colors.white,
        leading: IconButton(tooltip: '关闭', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : !_ready
                ? const CircularProgressIndicator(color: Colors.white)
                : GestureDetector(
                    onTap: () => _ctl.value.isPlaying ? _ctl.pause() : _ctl.play(),
                    child: Stack(alignment: Alignment.center, children: [
                      AspectRatio(aspectRatio: _ctl.value.aspectRatio, child: VideoPlayer(_ctl)),
                      if (!_ctl.value.isPlaying)
                        Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                        ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 24,
                        child: VideoProgressIndicator(_ctl, allowScrubbing: true, colors: const VideoProgressColors(playedColor: Colors.white)),
                      ),
                    ]),
                  ),
      ),
    );
  }
}
