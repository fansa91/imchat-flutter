import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imchat/src/api.dart';
import 'package:imchat/src/models.dart';
import 'package:imchat/src/recorder.dart';
import 'package:imchat/src/util.dart';
import 'package:imchat/src/voice_cache.dart';

// 样例 JSON 按 imserver 的 Go 结构体（encoding/json）输出格式编写
const userJson = '{"id":7,"email":"a@b.cc","nickname":"小明","avatar_url":"","created_at":"2026-10-01T08:00:00.123456789+08:00"}';

void main() {
  group('User', () {
    test('parses Go time with nanoseconds and offset', () {
      final u = User.fromJson(jsonDecode(userJson));
      expect(u.id, 7);
      expect(u.nickname, '小明');
      expect(u.createdAt!.toUtc(), DateTime.utc(2026, 10, 1, 0, 0, 0, 123, 456));
    });
  });

  group('Message', () {
    test('text message with reply, reactions, mod_seq', () {
      final m = Message.fromJson(jsonDecode('''
      {"conversation_id":3,"seq":42,"sender_id":7,"client_msg_id":"c-1","msg_type":1,"content":"你好",
       "created_at":"2026-10-14T07:00:00Z","reply_to_seq":40,
       "reply_to":{"seq":40,"sender_id":8,"msg_type":1,"preview":"在吗","recalled":false},
       "mod_seq":5,"reactions":[{"emoji":"👍","count":2,"user_ids":[7,8]}]}
      '''));
      expect(m.conversationId, 3);
      expect(m.seq, 42);
      expect(m.replyToSeq, 40);
      expect(m.replyTo!.preview, '在吗');
      expect(m.replyTo!.missing, isFalse);
      expect(m.reactions.single.userIds, [7, 8]);
      expect(m.modSeq, 5);
      expect(m.recalled, isFalse);
      expect(m.status, MsgStatus.sent);
    });

    test('omitted optional fields default sanely', () {
      final m = Message.fromJson(jsonDecode(
          '{"conversation_id":1,"seq":1,"sender_id":2,"client_msg_id":"x","msg_type":10,"content":"{}","created_at":"2026-10-14T07:00:00Z"}'));
      expect(m.replyToSeq, isNull);
      expect(m.replyTo, isNull);
      expect(m.reactions, isEmpty);
      expect(m.isSystem, isTrue);
    });

    test('recalled message', () {
      final m = Message.fromJson(jsonDecode(
          '{"conversation_id":1,"seq":9,"sender_id":2,"client_msg_id":"x","msg_type":3,"content":"","created_at":"2026-10-14T07:00:00Z","recalled":true,"recalled_at":"2026-10-14T07:01:00Z","mod_seq":3}'));
      expect(m.recalled, isTrue);
      expect(m.recalledAt, isNotNull);
      expect(VoiceContent.of(m), isNull);
    });

    test('round trip toJson', () {
      final src = jsonDecode(
          '{"conversation_id":1,"seq":9,"sender_id":2,"client_msg_id":"x","msg_type":1,"content":"hi","created_at":"2026-10-14T07:00:00.000Z","reply_to_seq":3}');
      final m = Message.fromJson(src);
      final again = Message.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(again.content, 'hi');
      expect(again.replyToSeq, 3);
      expect(again.createdAt, m.createdAt);
    });
  });

  group('VoiceContent', () {
    test('parse from message content and encode back', () {
      const content = '{"key":"voice/7/202610/abc.m4a","mime":"audio/mp4","duration_ms":3200,"size":12345,"waveform":[6,50,100]}';
      final m = Message(
        conversationId: 1,
        seq: 2,
        senderId: 7,
        clientMsgId: 'c',
        msgType: msgVoice,
        content: content,
        createdAt: DateTime.now(),
      );
      final v = VoiceContent.of(m)!;
      expect(v.key, 'voice/7/202610/abc.m4a');
      expect(v.durationMs, 3200);
      expect(v.waveform, [6, 50, 100]);
      final enc = jsonDecode(v.withKey('k2').encode()) as Map<String, dynamic>;
      expect(enc['key'], 'k2');
      expect(enc['mime'], 'audio/mp4');
      expect(enc['size'], 12345);
    });
  });

  group('Conversation', () {
    test('group summary', () {
      final c = Conversation.fromJson(jsonDecode('''
      {"id":5,"type":2,"last_seq":10,"mod_seq":2,"read_seq":8,"join_seq":0,"unread":2,
       "updated_at":"2026-10-14T07:00:00Z","name":"周末爬山","owner_id":7,"my_role":2,"member_count":3,
       "members_preview":[$userJson,{"id":8,"email":"c@d.cc","nickname":"","avatar_url":"","created_at":"2026-10-01T00:00:00Z"}],
       "announcement":"8点集合","announcement_by":7,"announcement_at":"2026-10-13T00:00:00Z",
       "last_message":{"conversation_id":5,"seq":10,"sender_id":8,"client_msg_id":"m","msg_type":1,"content":"ok","created_at":"2026-10-14T07:00:00Z"},
       "last_sender_name":"c"}
      '''));
      expect(c.isGroup, isTrue);
      expect(c.myRole, roleOwner);
      expect(c.membersPreview.length, 2);
      expect(c.lastMessage!.content, 'ok');
      expect(c.announcementAt, isNotNull);
      expect(convTitle(c), '周末爬山');
    });

    test('direct summary without optional fields', () {
      final c = Conversation.fromJson(jsonDecode(
          '{"id":1,"type":1,"last_seq":0,"mod_seq":0,"read_seq":0,"join_seq":0,"unread":0,"updated_at":"2026-10-14T07:00:00Z","peer":$userJson,"my_role":0}'));
      expect(c.isGroup, isFalse);
      expect(c.lastMessage, isNull);
      expect(convTitle(c), '小明');
    });
  });

  group('misc payloads', () {
    test('member / config / auth / presign / media', () {
      final mem = Member.fromJson(jsonDecode('{"user":$userJson,"role":1,"read_seq":4,"joined_at":"2026-10-01T00:00:00Z"}'));
      expect(mem.role, roleAdmin);
      expect(mem.user.id, 7);

      final cfg = ClientConfig.fromJson(jsonDecode(
          '{"recall_seconds":120,"group_max_members":500,"reactions":["❤️","👍"],"voice_enabled":true,"voice_max_seconds":60,"voice_max_bytes":1048576,"voice_ttl_days":7}'));
      expect(cfg.voiceEnabled, isTrue);
      expect(cfg.voiceMaxSeconds, 60);
      expect(cfg.reactions, ['❤️', '👍']);
      final cfg2 = ClientConfig.fromJson(jsonDecode('{"recall_seconds":60,"group_max_members":10,"reactions":[],"voice_enabled":false}'));
      expect(cfg2.voiceMaxSeconds, isNull);

      final auth = AuthResult.fromJson(jsonDecode('{"token":"jwt","expires_at":"2026-11-14T07:00:00Z","user":$userJson}'));
      expect(auth.token, 'jwt');
      expect(auth.user.email, 'a@b.cc');

      final pre = PresignResult.fromJson(jsonDecode(
          '{"key":"voice/7/x.m4a","url":"https://s3/x","method":"PUT","headers":{"Content-Type":"audio/mp4"},"expires_at":"2026-10-14T07:10:00Z","max_bytes":1048576}'));
      expect(pre.headers['Content-Type'], 'audio/mp4');

      final media = MediaInfo.fromJson(jsonDecode('{"url":"https://s3/get","mime":"audio/webm","size":99,"expires_at":"2026-10-14T07:10:00Z"}'));
      expect(media.mime, 'audio/webm');
    });
  });

  group('util', () {
    test('systemText replaces self with 你', () {
      final m = Message(
        conversationId: 1,
        seq: 1,
        senderId: 7,
        clientMsgId: 'c',
        msgType: msgSystem,
        content: jsonEncode({
          'op': 'create',
          'actor': {'id': 7, 'nickname': '小明'},
          'targets': [
            {'id': 8, 'nickname': '小红'},
          ],
          'name': '群',
          'text': 'x',
        }),
        createdAt: DateTime.now(),
      );
      expect(systemText(m, 7), '你 创建了群聊“群”，并邀请了 小红');
      expect(systemText(m, 8), '小明 创建了群聊“群”，并邀请了 你');
      expect(isMyExit(m, 7), isFalse);
    });

    test('isMyExit for remove', () {
      final m = Message(
        conversationId: 1,
        seq: 1,
        senderId: 7,
        clientMsgId: 'c',
        msgType: msgSystem,
        content: '{"op":"remove","actor":{"id":7,"nickname":"a"},"targets":[{"id":9,"nickname":"b"}],"text":""}',
        createdAt: DateTime.now(),
      );
      expect(isMyExit(m, 9), isTrue);
      expect(isMyExit(m, 7), isFalse);
    });

    test('listTime', () {
      final now = DateTime(2026, 10, 14, 15, 0);
      expect(listTime(DateTime(2026, 10, 14, 9, 5), now), '09:05');
      expect(listTime(DateTime(2026, 10, 13, 9, 5), now), '昨天');
      expect(listTime(DateTime(2026, 10, 11, 9, 5), now), '周日');
      expect(listTime(DateTime(2026, 3, 1), now), '3月1日');
      expect(listTime(DateTime(2025, 3, 1), now), '2025/3/1');
      expect(dayLabel(DateTime(2026, 10, 14, 9, 5), now), '今天 09:05');
    });

    test('server url helpers', () {
      expect(normalizeServer('im.example.com/'), 'https://im.example.com');
      expect(normalizeServer('http://10.0.0.2:8080'), 'http://10.0.0.2:8080');
      expect(wsUri('https://im.fansa.ccwu.cc', 'a b').toString(), 'wss://im.fansa.ccwu.cc/ws?token=a+b');
      expect(wsUri('http://10.0.0.2:8080', 't').toString(), 'ws://10.0.0.2:8080/ws?token=t');
    });

    test('downsample / fmtDuration', () {
      expect(downsample([], 4), [8, 8, 8, 8]);
      expect(downsample([0.0, 1.0, 0.5, 0.2], 2), [100, 50]);
      expect(fmtDuration(61000), '1:01');
    });
  });

  group('VoiceCache', () {
    test('put / find / delete', () async {
      final dir = await Directory.systemTemp.createTemp('imchat_test');
      final cache = await VoiceCache.at(dir);
      expect(await cache.find(1, 2), isNull);
      await cache.put(1, 2, 'audio/webm', utf8.encode('abc'));
      final f = await cache.find(1, 2);
      expect(f, isNotNull);
      expect(f!.path.endsWith('1_2.webm'), isTrue);
      await cache.delete(1, 2);
      expect(await cache.find(1, 2), isNull);
      await dir.delete(recursive: true);
    });
  });
}
