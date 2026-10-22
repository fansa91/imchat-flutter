import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imchat/src/file_cache.dart';
import 'package:imchat/src/image_prep.dart';
import 'package:imchat/src/models.dart';
import 'package:imchat/src/util.dart';
import 'package:image/image.dart' as img;

Message _msg(int type, String content, {bool recalled = false}) => Message(
      conversationId: 3,
      seq: 9,
      senderId: 7,
      clientMsgId: 'c',
      msgType: type,
      content: content,
      createdAt: DateTime(2026, 10, 22, 14, 3),
      recalled: recalled,
    );

void main() {
  group('message type constants', () {
    test('v0.4.0 types', () {
      expect(msgVideo, 4);
      expect(msgFile, 5);
      expect(msgCall, 6);
    });
  });

  group('VideoContent', () {
    test('round trip with poster', () {
      const raw =
          '{"key":"video/7/a.mp4","mime":"video/mp4","size":999,"duration_ms":32000,"width":1280,"height":720,"poster_key":"image/7/p.jpg"}';
      final vc = VideoContent.of(_msg(msgVideo, raw))!;
      expect(vc.key, 'video/7/a.mp4');
      expect(vc.mime, 'video/mp4');
      expect(vc.size, 999);
      expect(vc.durationMs, 32000);
      expect(vc.width, 1280);
      expect(vc.height, 720);
      expect(vc.posterKey, 'image/7/p.jpg');
      expect(jsonDecode(vc.encode()), jsonDecode(raw));
      expect(vc.withKey('k2').key, 'k2');
      expect(vc.withKey('k2').posterKey, 'image/7/p.jpg');
    });

    test('poster omitted when empty; of() guards', () {
      const vc = VideoContent(key: 'k', mime: 'video/webm', size: 1);
      expect(jsonDecode(vc.encode()).containsKey('poster_key'), isFalse);
      expect(VideoContent.of(_msg(msgVideo, '{}', recalled: true)), isNull);
      expect(VideoContent.of(_msg(msgFile, '{}')), isNull);
      expect(VideoContent.of(_msg(msgVideo, 'nope')), isNull);
    });
  });

  group('FileContent', () {
    test('round trip', () {
      const raw = '{"key":"file/7/a.pdf","mime":"application/pdf","size":2048,"name":"报告.pdf"}';
      final fc = FileContent.of(_msg(msgFile, raw))!;
      expect(fc.key, 'file/7/a.pdf');
      expect(fc.name, '报告.pdf');
      expect(fc.size, 2048);
      expect(jsonDecode(fc.encode()), jsonDecode(raw));
      expect(fc.withKey('x').name, '报告.pdf');
      expect(FileContent.of(_msg(msgFile, '{}', recalled: true)), isNull);
      expect(FileContent.of(_msg(msgVideo, '{}')), isNull);
    });
  });

  group('CallContent', () {
    test('parse all outcomes fields', () {
      const raw = '{"call_id":"abc","kind":"video","outcome":"completed","duration_ms":312000,"caller_id":42}';
      final cc = CallContent.of(_msg(msgCall, raw))!;
      expect(cc.callId, 'abc');
      expect(cc.kind, 'video');
      expect(cc.isVideo, isTrue);
      expect(cc.outcome, 'completed');
      expect(cc.durationMs, 312000);
      expect(cc.callerId, 42);
      expect(jsonDecode(cc.encode()), jsonDecode(raw));
    });

    test('defaults: kind audio when missing', () {
      final cc = CallContent.of(_msg(msgCall, '{"call_id":"x","outcome":"missed"}'))!;
      expect(cc.kind, 'audio');
      expect(cc.isVideo, isFalse);
      expect(CallContent.of(_msg(msgText, '{}')), isNull);
    });

    test('callText renders per outcome', () {
      String t(String kind, String outcome, [int dur = 0]) => callText(_msg(msgCall,
          jsonEncode({'call_id': 'c', 'kind': kind, 'outcome': outcome, 'duration_ms': dur, 'caller_id': 1})));
      expect(t('video', 'completed', 312000), '视频通话 05:12');
      expect(t('audio', 'completed', 65000), '语音通话 01:05');
      expect(t('audio', 'missed'), '语音通话 未接听');
      expect(t('video', 'rejected'), '视频通话 对方已拒绝');
      expect(t('audio', 'cancelled'), '语音通话 已取消');
      expect(t('audio', 'busy'), '语音通话 对方忙线');
      expect(t('audio', 'failed'), '语音通话 连接失败');
      expect(callText(_msg(msgCall, 'bad json')), '[通话]');
    });
  });

  group('ClientConfig v0.4.0 fields', () {
    test('missing fields default off/null (old server)', () {
      final cfg = ClientConfig.fromJson(jsonDecode('{"recall_seconds":120,"voice_enabled":true}'));
      expect(cfg.callEnabled, isFalse);
      expect(cfg.callRingTimeoutSeconds, isNull);
      expect(cfg.fileEnabled, isFalse);
      expect(cfg.fileMaxBytes, isNull);
      expect(cfg.videoEnabled, isFalse);
      expect(cfg.videoMaxBytes, isNull);
      expect(cfg.passwordResetEnabled, isFalse);
    });

    test('parses new fields', () {
      final cfg = ClientConfig.fromJson(jsonDecode(
          '{"call_enabled":true,"call_ring_timeout_seconds":45,"file_enabled":true,"file_max_bytes":104857600,"video_enabled":true,"video_max_bytes":52428800,"password_reset_enabled":true}'));
      expect(cfg.callEnabled, isTrue);
      expect(cfg.callRingTimeoutSeconds, 45);
      expect(cfg.fileEnabled, isTrue);
      expect(cfg.fileMaxBytes, 104857600);
      expect(cfg.videoEnabled, isTrue);
      expect(cfg.videoMaxBytes, 52428800);
      expect(cfg.passwordResetEnabled, isTrue);
    });

    test('const default config is all off', () {
      const cfg = ClientConfig();
      expect(cfg.callEnabled && cfg.fileEnabled && cfg.videoEnabled && cfg.passwordResetEnabled, isFalse);
    });
  });

  group('util v0.4.0', () {
    test('previews', () {
      expect(previewOf(_msg(msgVideo, '{}'), 1, (_) => 'x'), '[视频]');
      expect(
          previewOf(_msg(msgFile, '{"key":"k","mime":"application/pdf","size":1,"name":"a.pdf"}'), 1, (_) => 'x'),
          '[文件] a.pdf');
      expect(previewOf(_msg(msgFile, '{}'), 1, (_) => 'x'), '[文件]');
      expect(
          previewOf(
              _msg(msgCall, '{"call_id":"c","kind":"video","outcome":"missed","duration_ms":0,"caller_id":2}'),
              1,
              (_) => 'x'),
          '[视频通话]');
      expect(shortPreview(_msg(msgVideo, '{}')), '[视频]');
      expect(shortPreview(_msg(msgFile, '{}')), '[文件]');
      expect(shortPreview(_msg(msgCall, '{}')), '[通话]');
    });

    test('fmtBytes / fmtCallDuration', () {
      expect(fmtBytes(0), '0 B');
      expect(fmtBytes(2048), '2.0 KB');
      expect(fmtBytes(5242880), '5.0 MB');
      expect(fmtCallDuration(0), '00:00');
      expect(fmtCallDuration(312000), '05:12');
      expect(fmtCallDuration(3661000), '1:01:01');
    });
  });

  group('avatar prep', () {
    test('center-crops to square and caps at 512 jpeg', () {
      final src = img.Image(width: 1000, height: 500);
      img.fill(src, color: img.ColorRgb8(10, 20, 30));
      final out = prepareAvatarSync(img.encodePng(src));
      expect(out.mime, 'image/jpeg');
      // 裁后 500x500，长边不超过 512，不放大
      expect(out.width, 500);
      expect(out.height, 500);
      final big = img.Image(width: 1200, height: 900);
      final out2 = prepareAvatarSync(img.encodePng(big));
      expect(out2.width, 512);
      expect(out2.height, 512);
    });

    test('small square stays its size', () {
      final src = img.Image(width: 100, height: 100);
      final out = prepareAvatarSync(img.encodePng(src));
      expect((out.width, out.height), (100, 100));
    });
  });

  group('MediaFileCache', () {
    test('put / find / delete and extFor', () async {
      final dir = await Directory.systemTemp.createTemp('imchat_media_test');
      final cache = await MediaFileCache.at(dir);
      expect(MediaFileCache.extFor('video/mp4'), 'mp4');
      expect(MediaFileCache.extFor('application/octet-stream', 'x.zip'), 'zip');
      expect(MediaFileCache.extFor('application/pdf', '报告.pdf'), 'pdf');
      expect(await cache.find(3, 9), isNull);
      final f = await cache.put(3, 9, 'video/mp4', Uint8List.fromList([1, 2, 3]));
      expect(f.path.endsWith('3_9.mp4'), isTrue);
      expect((await cache.find(3, 9))!.path, f.path);
      final src = File('${dir.path}/orig.bin')..writeAsBytesSync([7]);
      final a = await cache.adopt(3, 10, 'application/pdf', src, 'a.pdf');
      expect(a.path.endsWith('3_10.pdf'), isTrue);
      expect(await cache.totalBytes(), greaterThan(0));
      await cache.delete(3, 9);
      expect(await cache.find(3, 9), isNull);
      await dir.delete(recursive: true);
    });
  });
}
