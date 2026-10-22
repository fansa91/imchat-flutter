import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'store.dart';

/// 通话阶段：idle 无通话 / outgoing 主叫响铃中 / incoming 被叫响铃中 /
/// connecting 已接听、协商中 / inCall 已接通（计时中）
enum CallPhase { idle, outgoing, incoming, connecting, inCall }

/// 1 对 1 音视频通话（SPEC v0.4.0 §1）：媒体 WebRTC P2P + Cloudflare TURN，
/// 信令经现有 WebSocket 的 call_* 事件。主叫固定为 offer 方；
/// 被叫在响铃阶段不建 PeerConnection、不申请权限，点接听后才 setup。
///
/// 无离线推送：来电只在被叫有在线 WS 连接时到达（SPEC §1.6），本类不做任何
/// 后台唤醒假象，App 被杀/冻结时服务端直接以 offline 终结并落未接记录。
class CallManager extends ChangeNotifier {
  CallManager(this.store);

  final ChatStore store;
  final _uuid = const Uuid();

  CallPhase phase = CallPhase.idle;
  String? callId;
  int? conversationId;
  int? peerId;
  String kind = 'audio'; // audio | video
  bool isCaller = false;
  DateTime? _connectedAt;
  Timer? _ticker;

  bool muted = false;
  bool cameraOff = false;
  bool speakerOn = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _remoteAnswered = false;

  /// 被叫接听前收到的 signal（offer/候选）先缓冲，接听 setup 时按序应用
  final List<Map<String, dynamic>> _bufferedSignals = [];

  bool get isVideo => kind == 'video';
  bool get active => phase != CallPhase.idle;

  Duration get elapsed {
    if (phase != CallPhase.inCall || _connectedAt == null) return Duration.zero;
    return DateTime.now().difference(_connectedAt!);
  }

  User? get peer {
    final cid = conversationId;
    if (cid != null) {
      final p = store.convs[cid]?.peer;
      if (p != null) return p;
    }
    return peerId != null ? store.users[peerId] : null;
  }

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  // ---------- 发起 ----------

  Future<void> startCall(int cid, String callKind) async {
    if (active) return;
    final conv = store.convs[cid];
    final peerUser = conv?.peer;
    if (conv == null || conv.isGroup || peerUser == null) return;
    callId = _uuid.v4();
    conversationId = cid;
    peerId = peerUser.id;
    kind = callKind;
    isCaller = true;
    phase = CallPhase.outgoing;
    notifyListeners();
    try {
      await _ensureRenderers();
      await _setupPeer();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      if (!store.socket.send('call_invite', {'call_id': callId, 'conversation_id': cid, 'kind': kind})) {
        throw StateError('offline');
      }
      _sendSignal({'kind': 'offer', 'sdp': offer.sdp, 'type': offer.type});
    } catch (e) {
      debugPrint('startCall failed: $e');
      store.socket.send('call_cancel', {'call_id': callId});
      store.showToast(e is StateError ? '网络未连接' : '无法访问摄像头/麦克风');
      _teardown();
    }
  }

  // ---------- 被叫操作 ----------

  Future<void> accept() async {
    if (phase != CallPhase.incoming || callId == null) return;
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      await _ensureRenderers();
      await _setupPeer();
      // 应用接听前缓冲的 offer/候选，再回 answer
      for (final s in _bufferedSignals.toList()) {
        await _applySignal(s);
      }
      _bufferedSignals.clear();
      store.socket.send('call_accept', {'call_id': callId});
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _sendSignal({'kind': 'answer', 'sdp': answer.sdp, 'type': answer.type});
    } catch (e) {
      debugPrint('accept failed: $e');
      store.socket.send('call_hangup', {'call_id': callId, 'reason': 'failed'});
      store.showToast('无法访问摄像头/麦克风');
      _teardown();
    }
  }

  void reject() {
    if (phase != CallPhase.incoming || callId == null) return;
    store.socket.send('call_reject', {'call_id': callId});
    _teardown();
  }

  /// 通话页的挂断按钮：按当前阶段映射到 cancel / reject / hangup
  void endByUser() {
    if (callId == null) return _teardown();
    switch (phase) {
      case CallPhase.outgoing:
        store.socket.send('call_cancel', {'call_id': callId});
      case CallPhase.incoming:
        store.socket.send('call_reject', {'call_id': callId});
      case CallPhase.connecting || CallPhase.inCall:
        store.socket.send('call_hangup', {'call_id': callId});
      case CallPhase.idle:
        return;
    }
    _teardown();
  }

  // ---------- 控制 ----------

  void toggleMute() {
    final tracks = _localStream?.getAudioTracks() ?? const [];
    if (tracks.isEmpty) return;
    muted = !muted;
    for (final t in tracks) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    cameraOff = !cameraOff;
    for (final t in tracks) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
    } catch (e) {
      debugPrint('switchCamera: $e');
    }
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    notifyListeners();
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (e) {
      debugPrint('setSpeakerphoneOn: $e'); // 桌面端无此概念，忽略
    }
  }

  // ---------- 信令处理（由 ChatStore 的 socket handler 转发） ----------

  void handleEvent(String type, Map<String, dynamic> d) {
    final id = d['call_id']?.toString();
    switch (type) {
      case 'call_invite':
        if (active || id == null) return; // 本机已在通话中：服务端应回 busy，这里兜底忽略
        callId = id;
        conversationId = (d['conversation_id'] as num?)?.toInt();
        peerId = (d['from_user_id'] as num?)?.toInt();
        kind = d['kind']?.toString() == 'video' ? 'video' : 'audio';
        isCaller = false;
        phase = CallPhase.incoming;
        _bufferedSignals.clear();
        notifyListeners();
      case 'call_signal':
        if (id == null || id != callId) return;
        final sig = d['signal'];
        if (sig is! Map<String, dynamic>) return;
        if (_pc == null) {
          _bufferedSignals.add(sig); // 被叫未接听（或主叫 pc 尚未建好）先缓冲
        } else {
          _applySignal(sig);
        }
      case 'call_accept':
        if (id != callId) return;
        if (isCaller && phase == CallPhase.outgoing) {
          phase = CallPhase.connecting;
          notifyListeners();
        }
      case 'call_reject':
        if (id != callId) return;
        store.showToast('对方已拒绝');
        _teardown();
      case 'call_cancel':
        if (id != callId) return;
        _teardown();
      case 'call_unavailable':
        if (id != callId) return;
        final reason = d['reason']?.toString();
        store.showToast(reason == 'busy' ? '对方忙线中' : '对方不在线');
        _teardown();
      case 'call_hangup':
        if (id != callId) return;
        final reason = d['reason']?.toString();
        if (reason == 'timeout') store.showToast(isCaller ? '对方未接听' : '对方已取消');
        // answered_elsewhere：本机其他设备已接听，静默结束响铃
        _teardown();
    }
  }

  void _sendSignal(Map<String, dynamic> signal) {
    store.socket.send('call_signal', {'call_id': callId, 'signal': signal});
  }

  Future<void> _applySignal(Map<String, dynamic> sig) async {
    final pc = _pc;
    if (pc == null) {
      _bufferedSignals.add(sig);
      return;
    }
    try {
      switch (sig['kind']?.toString()) {
        case 'offer':
          await pc.setRemoteDescription(RTCSessionDescription(sig['sdp']?.toString(), sig['type']?.toString() ?? 'offer'));
        case 'answer':
          if (_remoteAnswered) return;
          _remoteAnswered = true;
          await pc.setRemoteDescription(RTCSessionDescription(sig['sdp']?.toString(), sig['type']?.toString() ?? 'answer'));
        case 'candidate':
          final c = sig['candidate'];
          if (c is Map<String, dynamic>) {
            await pc.addCandidate(RTCIceCandidate(
              c['candidate']?.toString(),
              c['sdpMid']?.toString(),
              (c['sdpMLineIndex'] as num?)?.toInt(),
            ));
          }
      }
    } catch (e) {
      debugPrint('applySignal: $e');
    }
  }

  Future<void> _setupPeer() async {
    Map<String, dynamic> ice = {
      'iceServers': [
        {'urls': 'stun:stun.cloudflare.com:3478'},
      ],
    };
    try {
      final res = await store.api.iceServers();
      final list = res['iceServers'];
      if (list is List && list.isNotEmpty) ice = {'iceServers': list};
    } catch (e) {
      debugPrint('iceServers failed, fallback to stun only: $e');
    }
    final pc = await createPeerConnection({...ice, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    pc.onIceCandidate = (RTCIceCandidate c) {
      _sendSignal({
        'kind': 'candidate',
        'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
      });
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) remoteRenderer.srcObject = e.streams.first;
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (phase == CallPhase.connecting || phase == CallPhase.outgoing) {
          phase = CallPhase.inCall;
          _connectedAt = DateTime.now();
          _startTicker();
          notifyListeners();
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (active) {
          store.socket.send('call_hangup', {'call_id': callId, 'reason': 'failed'});
          store.showToast('连接失败');
          _teardown();
        }
      }
    };
    // 发起/接听时才申请麦克风（与摄像头）：flutter_webrtc 的 getUserMedia 触发系统权限弹窗
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }
          : false,
    });
    _localStream = stream;
    localRenderer.srcObject = stream;
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    if (isVideo) {
      speakerOn = true;
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (active) notifyListeners();
    });
  }

  void _teardown() {
    _ticker?.cancel();
    _ticker = null;
    final pc = _pc;
    _pc = null;
    pc?.close().catchError((_) {});
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        t.stop().catchError((_) {});
      }
      stream.dispose().catchError((_) {});
    }
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    phase = CallPhase.idle;
    callId = null;
    conversationId = null;
    peerId = null;
    isCaller = false;
    _connectedAt = null;
    _remoteAnswered = false;
    _bufferedSignals.clear();
    muted = false;
    cameraOff = false;
    speakerOn = false;
    notifyListeners();
  }

  /// 退出登录时强制结束
  void forceEnd() {
    if (active) _teardown();
  }

  @override
  void dispose() {
    _teardown();
    if (_renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}
