import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../recorder.dart';
import '../store.dart';
import 'voice_player.dart';

/// 语音气泡：播放/暂停 + 波形进度（点击/拖动跳转）+ 已播放/总时长。播放只用本地副本。
class VoiceBubble extends StatelessWidget {
  const VoiceBubble({super.key, required this.m, required this.mine});
  final Message m;
  final bool mine;

  static const int bars = 28;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final state = m.seq == 0 ? VoiceState.ready : context.select<ChatStore, VoiceState?>((s) => s.voice[s.voiceKeyOf(m)]);
    final player = context.watch<VoicePlayer>();
    final vc = VoiceContent.of(m);
    final dur = vc?.durationMs ?? 0;
    final id = m.seq > 0 ? store.voiceKeyOf(m) : m.clientMsgId;
    final playing = player.isPlaying(id);
    final pos = player.positionOf(id).inMilliseconds;
    final progress = dur == 0 ? 0.0 : (pos / dur).clamp(0.0, 1.0);
    final cs = Theme.of(context).colorScheme;
    final fg = mine ? cs.onPrimary : cs.onSurface;

    final src = (vc?.waveform.isNotEmpty ?? false) ? vc!.waveform : List.generate(bars, (i) => 20 + (i * 37) % 50);
    final heights = List.generate(bars, (i) {
      final a = (i * src.length) ~/ bars;
      final b = max(a + 1, ((i + 1) * src.length) ~/ bars);
      return src.sublist(a, min(b, src.length)).fold<int>(0, max);
    });

    Future<void> toggle() async {
      if (state == VoiceState.error) return store.retryVoice(m);
      if (state != VoiceState.ready) return;
      final f = await store.voiceFile(m);
      if (f == null) return store.retryVoice(m);
      try {
        await player.toggle(id, f);
      } catch (_) {
        store.showToast('无法播放这条语音');
      }
    }

    Future<void> seekTo(double ratio) async {
      if (state != VoiceState.ready || dur == 0) return;
      final f = await store.voiceFile(m);
      if (f == null) return;
      await player.seek(id, f, Duration(milliseconds: (ratio * dur).round()));
    }

    Widget leading;
    String? label;
    switch (state) {
      case VoiceState.loading:
      case null:
        leading = SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg));
        label = '下载中';
      case VoiceState.expired:
        leading = Icon(Icons.timer_off_outlined, color: fg);
        label = '语音已过期';
      case VoiceState.error:
        leading = Icon(Icons.refresh, color: fg);
        label = '加载失败，点击重试';
      case VoiceState.ready:
        leading = Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: fg);
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: playing ? '暂停' : '播放',
        onPressed: toggle,
        icon: leading,
      ),
      if (label != null && state != VoiceState.ready)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(label, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13)),
        )
      else
        LayoutBuilder(builder: (context, _) {
          const w = bars * 4.0;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekTo((d.localPosition.dx / w).clamp(0.0, 1.0)),
            onHorizontalDragUpdate: (d) => seekTo((d.localPosition.dx / w).clamp(0.0, 1.0)),
            child: SizedBox(
              width: w,
              height: 32,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < bars; i++)
                    Container(
                      width: 2.5,
                      margin: const EdgeInsets.only(right: 1.5),
                      height: max(3.0, 28 * heights[i] / 100),
                      decoration: BoxDecoration(
                        color: (i + 0.5) / bars <= progress ? fg : fg.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
      const SizedBox(width: 8),
      Text(
        playing || pos > 0 ? fmtDuration(pos) : fmtDuration(dur),
        style: TextStyle(color: fg, fontFeatures: const [FontFeature.tabularFigures()], fontSize: 13),
      ),
      const SizedBox(width: 4),
    ]);
  }
}
