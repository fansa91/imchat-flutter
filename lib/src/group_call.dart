import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'models.dart';
import 'store.dart';

/// 群通话邀请（group_call_started 即邀请，SPEC v0.5.0 §3.4）：不做逐人
/// 响铃状态机，只在任意页面弹可加入横幅，响铃超时后自动收起。
class GroupCallInvite {
  final String callId;
  final int conversationId;
  final String kind; // audio | video
  final User? creator;
  const GroupCallInvite({required this.callId, required this.conversationId, this.kind = 'audio', this.creator});
  bool get isVideo => kind == 'video';
}

/// 多人音视频通话（SPEC v0.5.0 §3）：群聊走 Cloudflare Realtime SFU，
/// 媒体与信令都经 imserver 代理接口（App Secret 只在服务端）。
/// 每位参与者在 SFU 侧有独立 session，本类只持本人 session 的一条
/// RTCPeerConnection：发布走 tracks/publish（offer → answer），
/// 订阅走 tracks/subscribe（Cloudflare 回 offer 时本地回 answer 再走
/// renegotiate 接口）。1 对 1 通话仍由 CallManager 负责，两者互斥。
class GroupCallManager extends ChangeNotifier {
  GroupCallManager(this.store);

  final ChatStore store;

  bool active = false;
  bool joining = false;

  /// 发布完成（offer/answer 已交换）
  bool connected = false;
  String? callId;
  int? conversationId;
  String kind = 'audio'; // audio | video
  String? _sessionId;
  DateTime? _startedAt;
  Timer? _ticker;

  bool muted = false;
  bool cameraOff = false;
  bool speakerOn = false;

  /// 房间成员（含自己），userId -> User
  final Map<int, User> participants = {};

  /// 已知 open 房间（按会话）：会话列表 / 群聊页「通话中」条与邀请横幅的数据源
  final Map<int, OpenRoom> openRooms = {};
  final Map<String, OpenRoom> _roomsByCallId = {};

  GroupCallInvite? invite;
  Timer? _inviteTimer;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  /// 远端轨道登记：key（userId/kind）与 mid 两套索引（onTrack 靠 mid 匹配）
  final Map<String, GroupTrackInfo> _tracksByKey = {};
  final Map<String, GroupTrackInfo> _tracksByMid = {};

  /// 已订阅的轨道 key，避免重复 subscribe
  final Set<String> _subscribed = {};

  /// 远端视频渲染器 / 流（按 userId）；音频流也挂在同一渲染器上出声
  final Map<int, RTCVideoRenderer> remoteRenderers = {};
  final Map<int, MediaStream> remoteStreams = {};

  bool get isVideo => kind == 'video';
  bool get inRoom => active && callId != null;

  Duration get elapsed => _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  User? get me => store.me;

  List<GroupTrackInfo> get knownTracks => _tracksByKey.values.toList();

  // ---------- 房间登记（事件驱动，供「通话中」条与横幅） ----------

  OpenRoom _upsertRoom(String cid, int conversationId, String kind, int creatorId) {
    final byCall = _roomsByCallId[cid];
    if (byCall != null) return byCall;
    final room = OpenRoom(callId: cid, conversationId: conversationId, kind: kind, creatorId: creatorId);
    if (creatorId != 0) room.joined(creatorId);
    _roomsByCallId[cid] = room;
    openRooms[conversationId] = room;
    return room;
  }

  void _removeRoom(String cid) {
    final room = _roomsByCallId.remove(cid);
    if (room != null && openRooms[room.conversationId]?.callId == cid) openRooms.remove(room.conversationId);
    if (invite?.callId == cid) _clearInvite();
  }

  void _clearInvite() {
    _inviteTimer?.cancel();
    _inviteTimer = null;
    invite = null;
  }

  // ---------- 发起 / 加入 ----------

  Future<void> startRoom(int cid, String callKind) async {
    if (active) return;
    if (store.calls.active) {
      store.showToast('你正在通话中');
      return;
    }
    final conv = store.convs[cid];
    if (conv == null || !conv.isGroup) return;
    joining = true;
    notifyListeners();
    try {
      final join = await store.api.createGroupCall(cid, callKind);
      await _enterRoom(join, cid, callKind);
    } catch (e) {
      debugPrint('startRoom failed: $e');
      store.showToast(e is ApiError ? e.message : '无法发起群通话');
      _teardown();
    }
  }

  Future<void> joinRoom(String roomCallId, {int conversationId = 0, String? kindHint}) async {
    if (active) return;
    if (store.calls.active) {
      store.showToast('你正在通话中');
      return;
    }
    joining = true;
    notifyListeners();
    try {
      final join = await store.api.joinGroupCall(roomCallId);
      final room = _roomsByCallId[roomCallId];
      await _enterRoom(
        join,
        conversationId != 0 ? conversationId : (room?.conversationId ?? 0),
        kindHint ?? room?.kind ?? 'audio',
      );
    } catch (e) {
      debugPrint('joinRoom failed: $e');
      store.showToast(e is ApiError ? e.message : '无法加入通话');
      _teardown();
    }
  }

  /// 从会话里的「通话中」条加入：房间登记里有 callId 直接 join
  Future<void> joinOpenRoom(int cid) async {
    final room = openRooms[cid];
    if (room == null) return;
    await joinRoom(room.callId);
  }

  Future<void> joinInvite() async {
    final inv = invite;
    if (inv == null) return;
    _clearInvite();
    notifyListeners();
    await joinRoom(inv.callId, conversationId: inv.conversationId, kindHint: inv.kind);
  }

  void dismissInvite() {
    _clearInvite();
    notifyListeners();
  }

  Future<void> _enterRoom(GroupCallJoin join, int cid, String callKind) async {
    callId = join.callId;
    _sessionId = join.sessionId;
    conversationId = cid != 0 ? cid : conversationId;
    kind = callKind;
    active = true;
    _clearInvite();
    final room = _upsertRoom(join.callId, conversationId ?? 0, kind, store.me?.id ?? 0);
    participants.clear();
    for (final u in join.participants) {
      participants[u.id] = u;
      store.users[u.id] = u;
      room.joined(u.id);
    }
    if (store.me != null) {
      participants[store.me!.id] = store.me!;
      room.joined(store.me!.id);
    }
    notifyListeners();
    store.ping();

    await _ensureRenderers();
    await _setupPeer(join.iceServers);
    await _publish();
    connected = true;
    _startedAt = DateTime.now();
    _startTicker();
    joining = false;
    notifyListeners();
    // 房间里已有的远端轨道一并订阅（GET 房间状态拿权威登记）
    await _syncFromServer();
  }

  // ---------- 媒体 ----------

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> _setupPeer(List<dynamic> iceServers) async {
    var ice = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.cloudflare.com:3478'},
      ],
    };
    if (iceServers.isNotEmpty) ice = {'iceServers': iceServers};
    final pc = await createPeerConnection({...ice, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    pc.onTrack = (RTCTrackEvent e) {
      final mid = e.transceiver?.mid.toString() ?? '';
      final info = _tracksByMid[mid];
      final stream = e.streams.isNotEmpty ? e.streams.first : null;
      if (info == null || stream == null) return;
      _attachRemote(info, stream);
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed && active) {
        store.showToast('通话连接失败');
        leave();
      }
    };
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
    if (isVideo) {
      speakerOn = true;
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
  }

  /// 发布本人轨道：track_name 由服务端分配为 {我的id}/audio|video，
  /// 与之不一致会被服务端拒绝（bad_track），这里严格照此拼装。
  Future<void> _publish() async {
    final pc = _pc;
    final stream = _localStream;
    final myId = store.me?.id;
    if (pc == null || stream == null || myId == null || callId == null) return;
    final tracks = <Map<String, dynamic>>[];
    for (final t in stream.getAudioTracks()) {
      await pc.addTrack(t, stream);
      tracks.add({'track_name': '$myId/audio', 'kind': 'audio'});
    }
    for (final t in stream.getVideoTracks()) {
      // 视频尽量带 simulcast 三层发布（720p/360p/180p，SPEC §3.6）；
      // 平台不支持 sendEncodings 时回退普通单层发布
      try {
        await pc.addTransceiver(
          track: t,
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly,
            streams: [stream],
            sendEncodings: [
              RTCRtpEncoding(rid: 'h', maxBitrate: 900 * 1000, maxFramerate: 30, scaleResolutionDownBy: 1.0),
              RTCRtpEncoding(rid: 'm', maxBitrate: 300 * 1000, maxFramerate: 20, scaleResolutionDownBy: 2.0),
              RTCRtpEncoding(rid: 'l', maxBitrate: 120 * 1000, maxFramerate: 15, scaleResolutionDownBy: 4.0),
            ],
          ),
        );
      } catch (e) {
        debugPrint('simulcast transceiver failed, fallback addTrack: $e');
        await pc.addTrack(t, stream);
      }
      tracks.add({'track_name': '$myId/video', 'kind': 'video'});
    }
    if (tracks.isEmpty) return;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    // 发布本地轨道必须带每条轨道在 offer 中对应 m-line 的 mid，缺了
    // Cloudflare 回 406 invalid_params「Missing mid in track」（v0.5.2 修）
    try {
      final midByKind = <String, String>{};
      for (final t in await pc.getTransceivers()) {
        final track = t.sender.track;
        final mid = t.mid;
        final k = track?.kind;
        if (track != null && mid.isNotEmpty && k != null && k.isNotEmpty) {
          midByKind[k] = mid;
        }
      }
      for (final t in tracks) {
        final m = midByKind[t['kind']];
        if (m != null) t['mid'] = m;
      }
    } catch (e) {
      debugPrint('collect track mids failed: $e');
    }
    final res = await store.api.publishTracks(callId!, {'type': offer.type ?? 'offer', 'sdp': offer.sdp ?? ''}, tracks);
    _registerPublishResult(res);
    if (res.sessionDescription != null && res.sdType == 'answer') {
      await pc.setRemoteDescription(RTCSessionDescription(res.sdp, 'answer'));
    }
  }

  /// 发布 / 订阅返回的 tracks 里带 mid，登记后 onTrack 才能对上号
  void _registerPublishResult(TracksResult res) {
    for (final t in res.tracks) {
      final name = (t['trackName'] ?? t['track_name'])?.toString() ?? '';
      final mid = t['mid']?.toString() ?? '';
      if (name.isEmpty || mid.isEmpty) continue;
      final owner = int.tryParse(name.split('/').first) ?? 0;
      final k = name.split('/').length > 1 ? name.split('/')[1] : 'audio';
      final info = GroupTrackInfo(userId: owner, trackName: name, kind: k, mid: mid, sessionId: _sessionId ?? '');
      _tracksByKey[info.key] = info;
      _tracksByMid[mid] = info;
    }
  }

  /// 订阅一批远端轨道（已订阅的自动跳过）
  Future<void> _subscribe(List<GroupTrackInfo> want) async {
    final pc = _pc;
    if (pc == null || callId == null) return;
    final myId = store.me?.id;
    final fresh = want.where((t) => t.userId != myId && !_subscribed.contains(t.key)).toList();
    if (fresh.isEmpty) return;
    for (final t in fresh) {
      _subscribed.add(t.key);
      _tracksByKey[t.key] = t;
      if (t.mid.isNotEmpty) _tracksByMid[t.mid] = t;
    }
    try {
      final res = await store.api.subscribeTracks(
        callId!,
        [for (final t in fresh) {'owner_id': t.userId, 'kind': t.kind}],
      );
      _registerPublishResult(res);
      final sd = res.sessionDescription;
      if (sd != null && res.sdType == 'offer') {
        // Cloudflare 给本人 session 生成了 offer：setRemote 后回 answer 走 renegotiate
        await pc.setRemoteDescription(RTCSessionDescription(res.sdp, 'offer'));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await store.api.renegotiateGroupCall(callId!, {'type': answer.type ?? 'answer', 'sdp': answer.sdp ?? ''});
      } else if (sd != null && res.sdType == 'answer') {
        await pc.setRemoteDescription(RTCSessionDescription(res.sdp, 'answer'));
      }
    } catch (e) {
      debugPrint('subscribe failed: $e');
      for (final t in fresh) {
        _subscribed.remove(t.key);
      }
    }
  }

  Future<void> _attachRemote(GroupTrackInfo info, MediaStream stream) async {
    remoteStreams[info.userId] = stream;
    if (info.kind == 'video') {
      final r = remoteRenderers.putIfAbsent(info.userId, RTCVideoRenderer.new);
      try {
        await r.initialize();
      } catch (_) {}
      r.srcObject = stream;
    }
    notifyListeners();
  }

  void _dropRemoteUser(int uid) {
    remoteStreams.remove(uid);
    final r = remoteRenderers.remove(uid);
    if (r != null) {
      r.srcObject = null;
      r.dispose();
    }
    for (final k in _tracksByKey.keys.where((k) => k.startsWith('$uid/')).toList()) {
      final info = _tracksByKey.remove(k);
      if (info != null) _tracksByMid.remove(info.mid);
      _subscribed.remove(k);
    }
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
    } catch (_) {}
  }

  /// 主动离开：先关本人轨道再退出成员集（服务端在房空时写通话记录）
  Future<void> leave() async {
    final id = callId;
    if (id != null) {
      final kinds = <String>[
        if ((_localStream?.getAudioTracks() ?? const []).isNotEmpty) 'audio',
        if ((_localStream?.getVideoTracks() ?? const []).isNotEmpty) 'video',
      ];
      if (kinds.isNotEmpty) {
        try {
          await store.api.closeGroupTracks(id, kinds);
        } catch (_) {}
      }
      try {
        await store.api.leaveGroupCall(id);
      } catch (_) {}
    }
    _teardown();
  }

  // ---------- 信令处理（由 ChatStore 的 socket handler 转发） ----------

  static int _uid(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

  void handleEvent(String type, Map<String, dynamic> d) {
    final cid = d['call_id']?.toString();
    switch (type) {
      case 'group_call_started':
        if (cid == null) return;
        final convId = _uid(d['conversation_id']);
        final creator = d['creator'] is Map<String, dynamic> ? User.fromJson(d['creator']) : null;
        final creatorId = creator?.id ?? _uid(d['creator_id'] ?? d['from_user_id']);
        final room = _upsertRoom(cid, convId, d['kind']?.toString() == 'video' ? 'video' : 'audio', creatorId);
        if (creator != null) store.users[creator.id] = creator;
        if (room.conversationId != 0 && creatorId != 0) room.joined(creatorId);
        // 我是发起人时房间由 _enterRoom 建好，不弹自己的邀请
        if (!active && creatorId != store.me?.id && !store.calls.active) {
          _clearInvite();
          invite = GroupCallInvite(
            callId: cid,
            conversationId: convId,
            kind: d['kind']?.toString() == 'video' ? 'video' : 'audio',
            creator: creator,
          );
          final secs = store.config.callRingTimeoutSeconds ?? 60;
          _inviteTimer = Timer(Duration(seconds: secs), () {
            if (invite?.callId == cid) {
              _clearInvite();
              notifyListeners();
            }
          });
        }
        notifyListeners();
        store.ping();
      case 'group_call_joined':
        if (cid == null) return;
        final room = _roomsByCallId[cid];
        final u = d['user'] is Map<String, dynamic> ? User.fromJson(d['user']) : null;
        final uid = u?.id ?? _uid(d['user_id']);
        room?.joined(uid);
        if (u != null) store.users[u.id] = u;
        if (inRoom && cid == callId && u != null) participants[u.id] = u;
        notifyListeners();
        store.ping();
      case 'group_call_tracks':
        if (cid == null) return;
        final uid = _uid(d['user_id']);
        final list = ((d['tracks'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((t) => GroupTrackInfo.fromJson({...t, 'user_id': t['user_id'] ?? uid}))
            .toList();
        for (final t in list) {
          _tracksByKey[t.key] = t;
          if (t.mid.isNotEmpty) _tracksByMid[t.mid] = t;
        }
        if (inRoom && cid == callId && uid != store.me?.id && list.isNotEmpty) {
          _subscribe(list);
        }
        notifyListeners();
      case 'group_call_tracks_closed':
        if (cid == null) return;
        final uid = _uid(d['user_id']);
        final kinds = ((d['kinds'] as List?) ?? const []).map((e) => e.toString()).toSet();
        for (final k in _tracksByKey.keys.where((k) => k.startsWith('$uid/')).toList()) {
          final info = _tracksByKey[k]!;
          if (kinds.isEmpty || kinds.contains(info.kind)) {
            _tracksByKey.remove(k);
            _tracksByMid.remove(info.mid);
            _subscribed.remove(k);
          }
        }
        if (kinds.contains('video') || kinds.isEmpty) {
          final r = remoteRenderers[uid];
          if (r != null) r.srcObject = null;
        }
        notifyListeners();
      case 'group_call_left':
        if (cid == null) return;
        final uid = _uid(d['user_id']);
        _roomsByCallId[cid]?.left(uid);
        if (inRoom && cid == callId) {
          participants.remove(uid);
          _dropRemoteUser(uid);
        }
        notifyListeners();
        store.ping();
      case 'group_call_ended':
        if (cid == null) return;
        _removeRoom(cid);
        if (inRoom && cid == callId) {
          store.showToast('通话已结束');
          _teardown();
          return;
        }
        notifyListeners();
        store.ping();
    }
  }

  /// WS 重连后恢复：本人在房间里则拉权威状态校正成员与轨道；
  /// 已知房间逐个校正计数，ended 的清掉（SPEC §3.7）
  Future<void> onReconnect() async {
    for (final room in _roomsByCallId.values.toList()) {
      if (inRoom && room.callId == callId) continue;
      try {
        final st = await store.api.groupCallState(room.callId);
        if (!st.isOpen) {
          _removeRoom(room.callId);
        } else {
          room.syncMembers(st.participants.map((u) => u.id));
        }
      } catch (_) {
        _removeRoom(room.callId);
      }
    }
    if (inRoom && callId != null) await _syncFromServer();
    notifyListeners();
    store.ping();
  }

  Future<void> _syncFromServer() async {
    final id = callId;
    if (id == null) return;
    try {
      final st = await store.api.groupCallState(id);
      if (!st.isOpen) {
        store.showToast('通话已结束');
        _teardown();
        return;
      }
      final room = _roomsByCallId[id];
      participants.clear();
      for (final u in st.participants) {
        participants[u.id] = u;
        store.users[u.id] = u;
      }
      if (store.me != null) participants[store.me!.id] = store.me!;
      room?.syncMembers(participants.keys);
      final remote = st.tracks.where((t) => t.userId != store.me?.id).toList();
      for (final t in remote) {
        _tracksByKey[t.key] = t;
        if (t.mid.isNotEmpty) _tracksByMid[t.mid] = t;
      }
      notifyListeners();
      await _subscribe(remote);
    } catch (e) {
      debugPrint('group call sync failed: $e');
    }
  }

  // ---------- 收尾 ----------

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
    for (final r in remoteRenderers.values) {
      r.srcObject = null;
      r.dispose();
    }
    remoteRenderers.clear();
    remoteStreams.clear();
    localRenderer.srcObject = null;
    participants.clear();
    _tracksByKey.clear();
    _tracksByMid.clear();
    _subscribed.clear();
    active = false;
    joining = false;
    connected = false;
    callId = null;
    conversationId = null;
    _sessionId = null;
    _startedAt = null;
    muted = false;
    cameraOff = false;
    speakerOn = false;
    notifyListeners();
    store.ping();
  }

  /// 退出登录时强制结束（不发 HTTP，token 即将失效）
  void forceEnd() {
    _clearInvite();
    openRooms.clear();
    _roomsByCallId.clear();
    if (active) _teardown();
  }

  @override
  void dispose() {
    _clearInvite();
    _teardown();
    if (_renderersReady) localRenderer.dispose();
    super.dispose();
  }
}
