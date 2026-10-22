import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:imchat/src/models.dart';
import 'package:imchat/src/ui/avatar.dart';
import 'package:imchat/src/util.dart';

Message _msg(int type, String content) => Message(
      conversationId: 3,
      seq: 9,
      senderId: 7,
      clientMsgId: 'c',
      msgType: type,
      content: content,
      createdAt: DateTime(2026, 10, 22, 15, 0),
    );

User _user({int id = 12, String nickname = '小明', String email = 'ming@example.com'}) =>
    User(id: id, nickname: nickname, email: email, avatarUrl: '/api/users/$id/avatar?v=abcd1234');

void main() {
  group('friendDisplayName（备注优先规则）', () {
    test('remark wins over nickname', () {
      expect(friendDisplayName(_user(), '明哥'), '明哥');
    });
    test('empty / blank remark falls back to nickname', () {
      expect(friendDisplayName(_user(), ''), '小明');
      expect(friendDisplayName(_user(), '   '), '小明');
    });
    test('remark is trimmed', () {
      expect(friendDisplayName(_user(), ' 明哥 '), '明哥');
    });
    test('no nickname falls back to email prefix, then 未知用户', () {
      expect(friendDisplayName(_user(nickname: ''), ''), 'ming');
      expect(friendDisplayName(_user(nickname: '', email: ''), ''), '未知用户');
      expect(friendDisplayName(null, ''), '未知用户');
      // 没有用户实体时备注无从附着，仍是未知用户
      expect(friendDisplayName(null, '明哥'), '未知用户');
    });
  });

  group('User.allowFind', () {
    test('parsed from /api/me response', () {
      final j = jsonDecode('{"id":1,"email":"a@b.c","nickname":"A","allow_find":false}') as Map<String, dynamic>;
      expect(User.fromJson(j).allowFind, isFalse);
    });
    test('absent (PublicUser) defaults to true', () {
      final j = jsonDecode('{"id":1,"nickname":"A"}') as Map<String, dynamic>;
      expect(User.fromJson(j).allowFind, isTrue);
    });
  });

  group('relation mapping', () {
    test('all four states round trip', () {
      for (final s in ['none', 'friend', 'pending_out', 'pending_in']) {
        expect(relationTo(relationFrom(s)), s);
      }
    });
    test('unknown / null maps to none', () {
      expect(relationFrom(null), UserRelation.none);
      expect(relationFrom('blocked'), UserRelation.none);
      expect(relationFrom(''), UserRelation.none);
    });
  });

  group('SearchResult.fromJson', () {
    test('public user + relation, no email leaked', () {
      final j = jsonDecode('{"id":12,"nickname":"小明","avatar_url":"/api/users/12/avatar?v=abcd1234","relation":"pending_in"}')
          as Map<String, dynamic>;
      final r = SearchResult.fromJson(j);
      expect(r.user.id, 12);
      expect(r.user.nickname, '小明');
      expect(r.user.email, '');
      expect(r.relation, UserRelation.pendingIn);
    });
    test('missing relation defaults to none', () {
      final j = jsonDecode('{"id":3,"nickname":"x"}') as Map<String, dynamic>;
      expect(SearchResult.fromJson(j).relation, UserRelation.none);
    });
  });

  group('Friend / FriendRequest.fromJson', () {
    test('friend with remark and online', () {
      final j = jsonDecode(
              '{"user":{"id":12,"nickname":"小明","avatar_url":""},"remark":"明哥","online":true,"created_at":"2026-10-22T10:00:00Z"}')
          as Map<String, dynamic>;
      final f = Friend.fromJson(j);
      expect(f.user.id, 12);
      expect(f.remark, '明哥');
      expect(f.online, isTrue);
      expect(f.createdAt, isNotNull);
      expect(f.copyWith(remark: '').remark, '');
    });
    test('friend defaults', () {
      final j = jsonDecode('{"user":{"id":5,"nickname":"y"}}') as Map<String, dynamic>;
      final f = Friend.fromJson(j);
      expect(f.remark, '');
      expect(f.online, isFalse);
    });
    test('request parse', () {
      final j = jsonDecode(
              '{"id":8,"user":{"id":9,"nickname":"阿华"},"message":"我是阿华","created_at":"2026-10-22T10:00:00Z"}')
          as Map<String, dynamic>;
      final r = FriendRequest.fromJson(j);
      expect(r.id, 8);
      expect(r.user.nickname, '阿华');
      expect(r.message, '我是阿华');
    });
  });

  group('ClientConfig v0.5.0 fields', () {
    test('group call fields parsed', () {
      final j = jsonDecode('{"group_call_enabled":true,"group_call_max_participants":9}') as Map<String, dynamic>;
      final c = ClientConfig.fromJson(j);
      expect(c.groupCallEnabled, isTrue);
      expect(c.groupCallMaxParticipants, 9);
    });
    test('absent fields default to disabled (old server)', () {
      final c = ClientConfig.fromJson(const {});
      expect(c.groupCallEnabled, isFalse);
      expect(c.groupCallMaxParticipants, isNull);
    });
  });

  group('CallContent group mode（SPEC §3.5）', () {
    test('group record fields parsed', () {
      const raw =
          '{"call_id":"g1","kind":"video","outcome":"completed","duration_ms":125000,"caller_id":7,"mode":"group","participant_count":8,"joined_count":5}';
      final cc = CallContent.of(_msg(msgCall, raw))!;
      expect(cc.isGroup, isTrue);
      expect(cc.participantCount, 8);
      expect(cc.joinedCount, 5);
    });
    test('old single record without mode stays single', () {
      const raw = '{"call_id":"s1","kind":"audio","outcome":"completed","duration_ms":1000,"caller_id":7}';
      final cc = CallContent.of(_msg(msgCall, raw))!;
      expect(cc.isGroup, isFalse);
      expect(cc.mode, 'single');
      expect(cc.joinedCount, 0);
    });
    test('callText renders group outcomes', () {
      const done =
          '{"call_id":"g1","kind":"video","outcome":"completed","duration_ms":125000,"caller_id":7,"mode":"group","joined_count":5}';
      expect(callText(_msg(msgCall, done)), '群视频通话 02:05 · 5 人参与');
      const missed = '{"call_id":"g2","kind":"audio","outcome":"missed","caller_id":7,"mode":"group"}';
      expect(callText(_msg(msgCall, missed)), '群语音通话 无人加入');
      const failed = '{"call_id":"g3","kind":"audio","outcome":"failed","caller_id":7,"mode":"group"}';
      expect(callText(_msg(msgCall, failed)), '群语音通话 连接失败');
      // 单聊文案不受影响
      const single = '{"call_id":"s1","kind":"audio","outcome":"completed","duration_ms":61000,"caller_id":7}';
      expect(callText(_msg(msgCall, single)), '语音通话 01:01');
    });
  });

  group('GroupCallState / GroupTrackInfo', () {
    test('state parse with participants and tracks', () {
      final j = jsonDecode('''{
        "state":"open","conversation_id":44,"kind":"video",
        "participants":[{"id":7,"nickname":"我"},{"id":12,"nickname":"小明"}],
        "tracks":[
          {"user_id":12,"track_name":"12/video","kind":"video","mid":"3","session_id":"sess12"},
          {"user_id":12,"track_name":"12/audio","kind":"audio","mid":"4","session_id":"sess12"}
        ]}''') as Map<String, dynamic>;
      final st = GroupCallState.fromJson(j);
      expect(st.isOpen, isTrue);
      expect(st.conversationId, 44);
      expect(st.kind, 'video');
      expect(st.participants.length, 2);
      expect(st.tracks.length, 2);
      expect(st.tracks.first.key, '12/video');
      expect(st.tracks.first.mid, '3');
    });
    test('ended state is not open; empty state defaults open', () {
      final j = jsonDecode('{"state":"ended"}') as Map<String, dynamic>;
      expect(GroupCallState.fromJson(j).isOpen, isFalse);
      expect(const GroupCallState().isOpen, isTrue);
    });
    test('track info tolerates owner_id / trackName spellings', () {
      final j = jsonDecode('{"owner_id":9,"trackName":"9/audio","sessionId":"s9"}') as Map<String, dynamic>;
      final t = GroupTrackInfo.fromJson(j);
      expect(t.userId, 9);
      expect(t.trackName, '9/audio');
      expect(t.kind, 'audio');
      expect(t.sessionId, 's9');
    });
  });

  group('TracksResult', () {
    test('answer passthrough', () {
      final j = jsonDecode(
              '{"sessionDescription":{"type":"answer","sdp":"v=0..."},"tracks":[{"trackName":"7/audio","mid":"0"}]}')
          as Map<String, dynamic>;
      final r = TracksResult.fromJson(j);
      expect(r.sdType, 'answer');
      expect(r.sdp, 'v=0...');
      expect(r.tracks.single['mid'], '0');
      expect(r.requiresImmediateRenegotiation, isFalse);
    });
    test('offer + renegotiation flag (snake_case keys)', () {
      final j = jsonDecode(
              '{"session_description":{"type":"offer","sdp":"v=0..."},"requires_immediate_renegotiation":true}')
          as Map<String, dynamic>;
      final r = TracksResult.fromJson(j);
      expect(r.sdType, 'offer');
      expect(r.requiresImmediateRenegotiation, isTrue);
    });
    test('empty response', () {
      final r = TracksResult.fromJson(const {});
      expect(r.sessionDescription, isNull);
      expect(r.tracks, isEmpty);
    });
  });

  group('OpenRoom bookkeeping', () {
    test('joined / left / count', () {
      final room = OpenRoom(callId: 'c1', conversationId: 44, kind: 'video', creatorId: 7);
      room.joined(7);
      room.joined(12);
      room.joined(12); // 去重
      room.joined(0); // 无效 id 忽略
      expect(room.count, 2);
      room.left(12);
      expect(room.count, 1);
      room.left(999);
      expect(room.count, 1);
    });
    test('syncMembers replaces with authoritative list', () {
      final room = OpenRoom(callId: 'c1', conversationId: 44, memberIds: {1, 2, 3});
      room.syncMembers([7, 12]);
      expect(room.memberIds, {7, 12});
      expect(room.count, 2);
    });
  });

  group('resolveAvatarUrl（头像相对路径拼接，含 ?v= 不得被编码成 %3F）', () {
    test('relative path with ?v= keeps the query string', () {
      expect(
        resolveAvatarUrl('https://im.example.com', '/api/users/10/avatar?v=abcd1234'),
        'https://im.example.com/api/users/10/avatar?v=abcd1234',
      );
    });
    test('unnormalized server input (no scheme, trailing slash)', () {
      expect(
        resolveAvatarUrl('im.example.com/', '/api/users/10/avatar?v=abcd1234'),
        'https://im.example.com/api/users/10/avatar?v=abcd1234',
      );
    });
    test('server with path prefix keeps prefix and query', () {
      expect(
        resolveAvatarUrl('https://example.com/im', '/api/users/10/avatar?v=x9'),
        'https://example.com/im/api/users/10/avatar?v=x9',
      );
    });
    test('relative path without query has no trailing ?', () {
      expect(
        resolveAvatarUrl('https://im.example.com', '/api/users/10/avatar'),
        'https://im.example.com/api/users/10/avatar',
      );
    });
    test('absolute url returned as-is', () {
      expect(
        resolveAvatarUrl('https://im.example.com', 'https://cdn.example.com/a.jpg?v=1'),
        'https://cdn.example.com/a.jpg?v=1',
      );
      expect(
        resolveAvatarUrl('https://im.example.com', 'http://cdn.example.com/a.jpg'),
        'http://cdn.example.com/a.jpg',
      );
    });
    test('empty string returns null', () {
      expect(resolveAvatarUrl('https://im.example.com', ''), isNull);
    });
  });

  group('GroupCallJoin.fromJson', () {
    // 服务端真实形状：ice_servers 是 TURN 原始回应对象 {iceServers: [...]}
    // （imserver respondRoom 原样嵌入）。早期测试误写成数组形状，掩盖了
    // 线上强转 List 抛错导致 Flutter 无法发起/加入群通话的 bug（v0.5.1 修）。
    test('parse join response (real server shape)', () {
      final j = jsonDecode('''{
        "call_id":"c1","session_id":"sess1",
        "ice_servers":{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},
          {"urls":["turn:turn.cloudflare.com:3478?transport=udp"],"username":"u","credential":"c"}],
          "expires_at":"2026-10-22T13:00:00Z"},
        "participants":[{"id":7,"nickname":"我"}]}''') as Map<String, dynamic>;
      final join = GroupCallJoin.fromJson(j);
      expect(join.callId, 'c1');
      expect(join.sessionId, 'sess1');
      expect(join.iceServers.length, 2);
      expect((join.iceServers[1] as Map)['username'], 'u');
      expect(join.participants.single.id, 7);
    });

    test('bare list shape still parses (defensive)', () {
      final j = jsonDecode('''{
        "call_id":"c2","session_id":"sess2",
        "ice_servers":[{"urls":["stun:stun.cloudflare.com:3478"]}],
        "participants":[]}''') as Map<String, dynamic>;
      expect(GroupCallJoin.fromJson(j).iceServers.length, 1);
    });

    test('missing ice_servers parses empty', () {
      final j = jsonDecode('{"call_id":"c3","session_id":"sess3"}') as Map<String, dynamic>;
      expect(GroupCallJoin.fromJson(j).iceServers, isEmpty);
    });
  });
}
