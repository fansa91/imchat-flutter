import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../recorder.dart' show fmtDuration;
import '../store.dart';
import 'avatar.dart';
import 'call_page.dart' show CallButton;

/// 群通话全屏页（SPEC v0.5.0 §3.7）：宫格布局（显示名走备注优先规则）、
/// 静音 / 关摄像头 / 离开；点某人放大（大窗 + 其余小条）。
/// 由 HomePage 在 GroupCallManager 处于通话中时覆盖显示。
class GroupCallPage extends StatefulWidget {
  const GroupCallPage({super.key});
  @override
  State<GroupCallPage> createState() => _GroupCallPageState();
}

class _GroupCallPageState extends State<GroupCallPage> {
  int? _focused;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final gc = store.groupCalls;
    return ListenableBuilder(
      listenable: gc,
      builder: (context, _) {
        if (!gc.active) return const SizedBox.shrink();
        final meId = store.me?.id;
        final others = gc.participants.values.where((u) => u.id != meId).toList()
          ..sort((a, b) => store.displayOf(a).compareTo(store.displayOf(b)));
        final all = [if (store.me != null) store.me!, ...others];
        // 放大对象已离开时自动取消放大
        final focusedUser = _focused != null ? gc.participants[_focused] : null;
        final statusText = !gc.connected
            ? '正在连接…'
            : gc.joining
                ? '正在加入…'
                : '${gc.participants.length} 人通话中 · ${fmtDuration(gc.elapsed.inMilliseconds)}';

        Widget tile(User u, {bool big = false}) => _Tile(
              key: ValueKey(u.id),
              user: u,
              isMe: u.id == meId,
              big: big,
              onTap: () => setState(() => _focused = _focused == u.id ? null : u.id),
            );

        Widget grid = GridView.count(
          crossAxisCount: all.length <= 2 ? 1 : 2,
          childAspectRatio: all.length <= 2 ? 1.6 : 0.9,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
          children: [for (final u in all) tile(u)],
        );

        Widget body;
        if (focusedUser != null) {
          body = Column(children: [
            Expanded(child: tile(focusedUser, big: true)),
            SizedBox(
              height: 110,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final u in all)
                    if (u.id != focusedUser.id)
                      SizedBox(width: 90, child: Padding(padding: const EdgeInsets.all(2), child: tile(u))),
                ],
              ),
            ),
          ]);
        } else {
          body = grid;
        }

        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      gc.isVideo ? '视频通话' : '语音通话',
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(statusText,
                      style: const TextStyle(color: Colors.white70, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
                ]),
              ),
              Expanded(child: body),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  CallButton(
                    icon: gc.muted ? Icons.mic_off : Icons.mic,
                    color: gc.muted ? Colors.white : Colors.white24,
                    iconColor: gc.muted ? Colors.black : Colors.white,
                    label: '静音',
                    onTap: gc.toggleMute,
                  ),
                  CallButton(
                    icon: gc.speakerOn ? Icons.volume_up : Icons.volume_down,
                    color: gc.speakerOn ? Colors.white : Colors.white24,
                    iconColor: gc.speakerOn ? Colors.black : Colors.white,
                    label: '免提',
                    onTap: () => gc.toggleSpeaker(),
                  ),
                  if (gc.isVideo)
                    CallButton(
                      icon: gc.cameraOff ? Icons.videocam_off : Icons.videocam,
                      color: gc.cameraOff ? Colors.white : Colors.white24,
                      iconColor: gc.cameraOff ? Colors.black : Colors.white,
                      label: '摄像头',
                      onTap: gc.toggleCamera,
                    ),
                  if (gc.isVideo)
                    CallButton(
                      icon: Icons.cameraswitch_outlined,
                      color: Colors.white24,
                      label: '切换摄像头',
                      onTap: () => gc.switchCamera(),
                    ),
                  CallButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    label: '离开',
                    size: 64,
                    onTap: () => gc.leave(),
                  ),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.user, required this.isMe, this.big = false, required this.onTap});

  final User user;
  final bool isMe;
  final bool big;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final store = context.read<ChatStore>();
    final gc = store.groupCalls;
    final name = isMe ? '我' : store.displayOf(user);
    RTCVideoRenderer? renderer;
    if (isMe) {
      if (gc.isVideo && !gc.cameraOff) renderer = gc.localRenderer;
    } else {
      renderer = gc.remoteRenderers[user.id];
      if (renderer?.srcObject == null) renderer = null;
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: Colors.grey.shade900,
        child: Stack(children: [
          Positioned.fill(
            child: renderer != null
                ? RTCVideoView(
                    renderer,
                    mirror: isMe,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    placeholderBuilder: (_) => const ColoredBox(color: Colors.black),
                  )
                : Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      UserAvatar(user: user, size: big ? 84 : 52),
                      const SizedBox(height: 8),
                      Text(name, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    ]),
                  ),
          ),
          Positioned(
            left: 8,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ),
        ]),
      ),
    );
  }
}
