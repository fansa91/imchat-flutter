import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../call.dart';
import '../recorder.dart' show fmtDuration;
import '../store.dart';
import 'avatar.dart';

/// 通话全屏页（SPEC v0.4.0 §1.5）：来电（头像/昵称/接听拒绝）与通话中
/// （对方画面全屏、本地小窗、静音/免提/切摄像头/关摄像头/挂断；语音通话显示头像与计时）。
/// 由 HomePage 在 CallManager 处于非 idle 阶段时覆盖显示。
class CallPage extends StatelessWidget {
  const CallPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final calls = store.calls;
    return ListenableBuilder(
      listenable: calls,
      builder: (context, _) {
        if (!calls.active) return const SizedBox.shrink();
        final peer = calls.peer;
        final name = store.displayOf(peer);
        final phase = calls.phase;
        final ringing = phase == CallPhase.incoming || phase == CallPhase.outgoing;
        final statusText = switch (phase) {
          CallPhase.incoming => calls.isVideo ? '邀请你视频通话…' : '邀请你语音通话…',
          CallPhase.outgoing => '正在呼叫…',
          CallPhase.connecting => '正在连接…',
          CallPhase.inCall => fmtDuration(calls.elapsed.inMilliseconds),
          CallPhase.idle => '',
        };

        Widget background;
        if (calls.isVideo && !ringing) {
          background = RTCVideoView(
            calls.remoteRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            placeholderBuilder: (_) => const ColoredBox(color: Colors.black),
          );
        } else {
          background = const ColoredBox(color: Colors.black);
        }

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            Positioned.fill(child: background),
            SafeArea(
              child: Column(children: [
                const SizedBox(height: 48),
                if (calls.isVideo && !ringing)
                  Align(
                    alignment: Alignment.center,
                    child: Text(statusText,
                        style: const TextStyle(color: Colors.white70, fontSize: 15, fontFeatures: [FontFeature.tabularFigures()])),
                  )
                else ...[
                  UserAvatar(user: peer, size: 96),
                  const SizedBox(height: 16),
                  Text(name, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(statusText,
                      style: const TextStyle(color: Colors.white70, fontSize: 15, fontFeatures: [FontFeature.tabularFigures()])),
                ],
                const Spacer(),
                if (phase == CallPhase.incoming)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 56),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      CallButton(
                        icon: Icons.call_end,
                        color: Colors.red,
                        label: '拒绝',
                        onTap: calls.reject,
                      ),
                      CallButton(
                        icon: calls.isVideo ? Icons.videocam : Icons.call,
                        color: Colors.green,
                        label: '接听',
                        size: 72,
                        onTap: () => calls.accept(),
                      ),
                    ]),
                  )
                else ...[
                  if (phase == CallPhase.inCall || phase == CallPhase.connecting)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                        CallButton(
                          icon: calls.muted ? Icons.mic_off : Icons.mic,
                          color: calls.muted ? Colors.white : Colors.white24,
                          iconColor: calls.muted ? Colors.black : Colors.white,
                          label: '静音',
                          onTap: calls.toggleMute,
                        ),
                        CallButton(
                          icon: calls.speakerOn ? Icons.volume_up : Icons.volume_down,
                          color: calls.speakerOn ? Colors.white : Colors.white24,
                          iconColor: calls.speakerOn ? Colors.black : Colors.white,
                          label: '免提',
                          onTap: () => calls.toggleSpeaker(),
                        ),
                        if (calls.isVideo) ...[
                          CallButton(
                            icon: Icons.cameraswitch_outlined,
                            color: Colors.white24,
                            label: '切换摄像头',
                            onTap: () => calls.switchCamera(),
                          ),
                          CallButton(
                            icon: calls.cameraOff ? Icons.videocam_off : Icons.videocam,
                            color: calls.cameraOff ? Colors.white : Colors.white24,
                            iconColor: calls.cameraOff ? Colors.black : Colors.white,
                            label: '摄像头',
                            onTap: calls.toggleCamera,
                          ),
                        ],
                      ]),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 56),
                    child: CallButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: phase == CallPhase.outgoing ? '取消' : '挂断',
                      size: 72,
                      onTap: calls.endByUser,
                    ),
                  ),
                ],
              ]),
            ),
            if (calls.isVideo && !ringing)
              Positioned(
                right: 16,
                top: 100,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 108,
                    height: 160,
                    child: RTCVideoView(
                      calls.localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      placeholderBuilder: (_) => const ColoredBox(color: Colors.black54),
                    ),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }
}

/// 通话控制按钮（1 对 1 与群通话页共用）
class CallButton extends StatelessWidget {
  const CallButton({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.size = 60,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  final double size;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: iconColor, size: size * 0.45),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ]);
  }
}
