import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../recorder.dart';
import '../store.dart';
import '../util.dart';

final Map<int, String> _drafts = {};

bool get isDesktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// 输入栏：文字 / 语音。
/// 语音：移动端按住麦克风说话，松开发送，按住时左滑取消；
/// 桌面端（或移动端轻点）点一下开始录音，再点发送 / 取消。最长 60 秒（以服务器配置为准）。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.id,
    required this.replyTo,
    required this.onCancelReply,
    required this.onSent,
  });

  final int id;
  final Message? replyTo;
  final VoidCallback onCancelReply;
  final VoidCallback onSent;

  @override
  State<Composer> createState() => ComposerState();
}

class _RecState {
  int elapsed = 0;
  List<double> levels = [];
  bool holding;
  bool cancelHint = false;
  _RecState(this.holding);
}

class ComposerState extends State<Composer> {
  late final TextEditingController _text = TextEditingController(text: _drafts[widget.id] ?? '');
  final FocusNode _focus = FocusNode();
  VoiceRecorder? _recorder;
  _RecState? _rec;
  ({DateTime start, double x})? _hold;
  DateTime _tapModeAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _recorder?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void focus() => _focus.requestFocus();

  void setText(String t) {
    _text.text = t;
    _text.selection = TextSelection.collapsed(offset: t.length);
    _drafts[widget.id] = t;
    setState(() {});
    focus();
  }

  // 桌面 Enter 发送、Shift+Enter 换行；触屏设备 Enter 换行
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!isDesktop || e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
      if (_text.value.composing.isValid && !_text.value.composing.isCollapsed) return KeyEventResult.ignored; // 输入法组字中
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final store = context.read<ChatStore>();
    if (_text.text.trim().isEmpty) return;
    store.send(widget.id, _text.text, replyToSeq: widget.replyTo?.seq);
    _text.clear();
    _drafts.remove(widget.id);
    setState(() {});
    widget.onSent();
    focus();
  }

  /// 选图发送：移动端可选相册 / 拍照，桌面端打开文件选择（可多选，最多 9 张）
  Future<void> _pickImage() async {
    final store = context.read<ChatStore>();
    var source = ImageSource.gallery;
    if (Platform.isAndroid || Platform.isIOS) {
      final s = await showModalBottomSheet<ImageSource>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );
      if (s == null) return;
      source = s;
    }
    final picker = ImagePicker();
    List<XFile> files;
    try {
      if (source == ImageSource.camera) {
        final f = await picker.pickImage(source: ImageSource.camera);
        files = f == null ? const [] : [f];
      } else {
        files = await picker.pickMultiImage(limit: 9);
      }
    } catch (e) {
      store.showToast(source == ImageSource.camera ? '无法打开相机' : '无法打开图片选择');
      return;
    }
    if (files.isEmpty) return;
    int? reply = widget.replyTo?.seq;
    widget.onSent();
    for (final f in files.take(9)) {
      try {
        final bytes = await f.readAsBytes();
        await store.sendImage(widget.id, bytes, replyToSeq: reply);
      } catch (_) {
        store.showToast('无法读取图片');
      }
      reply = null; // 只有第一张带引用
    }
  }

  /// 选视频发送：相册视频 / 拍摄；元数据（时长/宽高/mime）用 video_player 探测
  Future<void> _pickVideo() async {
    final store = context.read<ChatStore>();
    var source = ImageSource.gallery;
    if (Platform.isAndroid || Platform.isIOS) {
      final s = await showModalBottomSheet<ImageSource>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('从相册选择视频'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('拍摄视频'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );
      if (s == null) return;
      source = s;
    }
    XFile? xf;
    try {
      xf = await ImagePicker().pickVideo(source: source, maxDuration: const Duration(minutes: 10));
    } catch (_) {
      store.showToast('无法打开视频选择');
      return;
    }
    if (xf == null) return;
    final file = File(xf.path);
    var durationMs = 0, width = 0, height = 0;
    VideoPlayerController? probe;
    try {
      probe = VideoPlayerController.file(file);
      await probe.initialize();
      durationMs = probe.value.duration.inMilliseconds;
      width = probe.value.size.width.round();
      height = probe.value.size.height.round();
    } catch (_) {
      // 探测失败不阻塞发送，宽高/时长填 0（服务端校验会拒绝时再提示）
    } finally {
      await probe?.dispose();
    }
    final mime = _videoMime(xf.name, xf.mimeType);
    widget.onSent();
    await store.sendVideoFile(
      widget.id,
      file,
      mime: mime,
      durationMs: durationMs,
      width: width,
      height: height,
      replyToSeq: widget.replyTo?.seq,
    );
  }

  static String _videoMime(String name, String? pickerMime) {
    if (pickerMime != null && pickerMime.startsWith('video/')) return pickerMime;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'webm' => 'video/webm',
      'mov' => 'video/quicktime',
      _ => 'video/mp4',
    };
  }

  static String _fileMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      'txt' || 'md' => 'text/plain',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'mp4' => 'video/mp4',
      'mp3' => 'audio/mpeg',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      _ => 'application/octet-stream',
    };
  }

  /// 选文件发送（单个，原样上传）
  Future<void> _pickFile() async {
    final store = context.read<ChatStore>();
    XFile? xf;
    try {
      xf = await openFile();
    } catch (_) {
      store.showToast('无法打开文件选择');
      return;
    }
    if (xf == null) return;
    widget.onSent();
    await store.sendFileMessage(widget.id, File(xf.path),
        name: xf.name, mime: _fileMime(xf.name), replyToSeq: widget.replyTo?.seq);
  }

  int get _maxSec => context.read<ChatStore>().config.voiceMaxSeconds ?? 60;

  Future<void> _startRecording() async {
    if (_recorder != null) return;
    final store = context.read<ChatStore>();
    final r = VoiceRecorder(_maxSec * 1000);
    _recorder = r;
    setState(() => _rec = _RecState(_hold != null));
    r.onLevel = (level, elapsed) {
      if (!mounted || _rec == null) return;
      setState(() {
        _rec!.elapsed = elapsed;
        _rec!.levels = [..._rec!.levels.length >= 40 ? _rec!.levels.sublist(_rec!.levels.length - 39) : _rec!.levels, level];
      });
    };
    r.onAutoStop = () => _finishRecording(true);
    try {
      await r.start();
    } catch (e) {
      _recorder = null;
      _hold = null;
      if (mounted) setState(() => _rec = null);
      store.showToast(e is RecorderException && e.code == 'permission' ? '没有麦克风权限' : '无法开始录音');
    }
  }

  Future<void> _finishRecording(bool sendIt) async {
    final r = _recorder;
    if (r == null) return;
    final store = context.read<ChatStore>();
    _recorder = null;
    _hold = null;
    setState(() => _rec = null);
    if (!sendIt) {
      await r.cancel();
      return;
    }
    final out = await r.stop();
    if (out == null) return;
    if (out.durationMs < 700) {
      try {
        await out.file.delete();
      } catch (_) {}
      store.showToast('说话时间太短');
      return;
    }
    store.sendVoice(widget.id, out, replyToSeq: widget.replyTo?.seq);
    widget.onSent();
  }

  // 按住说话
  void _onMicDown(PointerDownEvent e) {
    if (_rec != null) return;
    _hold = (start: DateTime.now(), x: e.position.dx);
    _startRecording();
  }

  void _onMicMove(PointerMoveEvent e) {
    final h = _hold;
    if (h == null || _rec == null) return;
    final cancel = e.position.dx - h.x < -80;
    if (cancel != _rec!.cancelHint) setState(() => _rec!.cancelHint = cancel);
  }

  void _onMicUp(PointerUpEvent e) {
    final h = _hold;
    if (h == null) return;
    // 桌面端或只是点了一下：进入“点按录音”模式，等用户点发送 / 取消
    if (isDesktop || DateTime.now().difference(h.start).inMilliseconds < 350) {
      _hold = null;
      _tapModeAt = DateTime.now();
      if (_rec != null) setState(() => _rec!.holding = false);
      return;
    }
    _finishRecording(e.position.dx - h.x >= -80);
  }

  bool get _tapGuard => DateTime.now().difference(_tapModeAt).inMilliseconds > 500;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final voiceEnabled = context.select<ChatStore, bool>((s) => s.config.voiceEnabled);
    final imageEnabled = context.select<ChatStore, bool>((s) => s.config.imageEnabled);
    final videoEnabled = context.select<ChatStore, bool>((s) => s.config.videoEnabled);
    final fileEnabled = context.select<ChatStore, bool>((s) => s.config.fileEnabled);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final reply = widget.replyTo;
    final hasText = _text.text.trim().isNotEmpty;
    final rec = _rec;

    Widget field;
    if (rec != null) {
      final maxMs = _maxSec * 1000;
      final hint = rec.holding ? (rec.cancelHint ? '松开取消' : '松开发送，左滑取消') : '点 ➤ 发送';
      field = Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        decoration: BoxDecoration(
          color: rec.cancelHint ? cs.errorContainer : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            if (!rec.holding)
              IconButton(
                tooltip: '取消录音',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _tapGuard ? _finishRecording(false) : null,
              )
            else
              const SizedBox(width: 12),
            Icon(Icons.fiber_manual_record, color: cs.error, size: 14),
            const SizedBox(width: 6),
            Text('${fmtDuration(rec.elapsed)} / ${fmtDuration(maxMs)}',
                style: tt.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 28,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (final l in rec.levels)
                      Container(
                        width: 2.5,
                        margin: const EdgeInsets.only(left: 1.5),
                        height: 4 + 22 * l,
                        decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(2)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(hint, style: tt.bodySmall?.copyWith(color: rec.cancelHint ? cs.onErrorContainer : cs.onSurfaceVariant)),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 0, 4),
            child: LinearProgressIndicator(value: (rec.elapsed / maxMs).clamp(0.0, 1.0)),
          ),
        ]),
      );
    } else {
      field = TextField(
        controller: _text,
        focusNode: _focus,
        minLines: 1,
        maxLines: 6,
        maxLength: 5000,
        textInputAction: isDesktop ? TextInputAction.newline : TextInputAction.newline,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(
          hintText: '发消息',
          counterText: '',
          filled: true,
          fillColor: cs.surfaceContainerHigh,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
        ),
        onChanged: (v) {
          _drafts[widget.id] = v;
          if (v.isNotEmpty) store.sendTyping(widget.id);
          setState(() {});
        },
      );
    }

    Widget button;
    if (rec != null && !rec.holding) {
      button = IconButton.filled(
        tooltip: '发送语音',
        icon: const Icon(Icons.send),
        onPressed: () => _tapGuard ? _finishRecording(true) : null,
      );
    } else if (hasText || !voiceEnabled) {
      button = IconButton.filled(
        tooltip: '发送',
        icon: const Icon(Icons.send),
        onPressed: hasText ? _send : null,
      );
    } else {
      button = Listener(
        onPointerDown: _onMicDown,
        onPointerMove: _onMicMove,
        onPointerUp: _onMicUp,
        onPointerCancel: (_) => _finishRecording(false),
        child: Tooltip(
          message: isDesktop ? '点击开始录音' : '按住说话，或轻点录音',
          triggerMode: TooltipTriggerMode.manual,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: rec != null ? 56 : 48,
            height: rec != null ? 56 : 48,
            decoration: BoxDecoration(
              color: rec != null ? cs.error : cs.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.mic, color: rec != null ? cs.onError : cs.onPrimaryContainer),
          ),
        ),
      );
    }

    return Material(
      color: cs.surface,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (reply != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
              child: Row(children: [
                Icon(Icons.reply, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('回复 ${store.nameOf(reply.senderId)}', style: tt.labelMedium?.copyWith(color: cs.primary)),
                    Text(
                      shortPreview(reply),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ]),
                ),
                IconButton(tooltip: '取消回复', icon: const Icon(Icons.close, size: 20), onPressed: widget.onCancelReply),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (imageEnabled && rec == null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(
                    tooltip: '发送图片',
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: _pickImage,
                  ),
                ),
              if ((videoEnabled || fileEnabled) && rec == null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(
                    tooltip: '发送视频 / 文件',
                    icon: const Icon(Icons.attach_file),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      showDragHandle: true,
                      builder: (ctx) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          if (videoEnabled)
                            ListTile(
                              leading: const Icon(Icons.video_library_outlined),
                              title: const Text('发送视频'),
                              onTap: () {
                                Navigator.pop(ctx);
                                _pickVideo();
                              },
                            ),
                          if (fileEnabled)
                            ListTile(
                              leading: const Icon(Icons.folder_open_outlined),
                              title: const Text('发送文件'),
                              onTap: () {
                                Navigator.pop(ctx);
                                _pickFile();
                              },
                            ),
                          const SizedBox(height: 8),
                        ]),
                      ),
                    ),
                  ),
                ),
              Expanded(child: field),
              const SizedBox(width: 8),
              button,
            ]),
          ),
        ]),
      ),
    );
  }
}
