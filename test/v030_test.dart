import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:imchat/src/api.dart';
import 'package:imchat/src/image_cache.dart';
import 'package:imchat/src/image_prep.dart';
import 'package:imchat/src/models.dart';
import 'package:imchat/src/store.dart' show transcribeError;
import 'package:imchat/src/theme.dart';
import 'package:imchat/src/util.dart';

Message _msg(int type, String content, {bool recalled = false}) => Message(
      conversationId: 3,
      seq: 9,
      senderId: 7,
      clientMsgId: 'c',
      msgType: type,
      content: content,
      createdAt: DateTime(2026, 10, 15, 14, 3),
      recalled: recalled,
    );

void main() {
  group('ImageContent', () {
    test('round trip and of()', () {
      const raw = '{"key":"image/7/abc.jpg","mime":"image/jpeg","size":12345,"width":1024,"height":768}';
      final m = _msg(msgImage, raw);
      final ic = ImageContent.of(m)!;
      expect(ic.key, 'image/7/abc.jpg');
      expect(ic.mime, 'image/jpeg');
      expect(ic.size, 12345);
      expect(ic.width, 1024);
      expect(ic.height, 768);
      expect(jsonDecode(ic.encode()), jsonDecode(raw));
      expect(ic.withKey('k2').key, 'k2');
      expect(ic.withKey('k2').width, 1024);
    });

    test('of() returns null for recalled / other types / bad json', () {
      expect(ImageContent.of(_msg(msgImage, '{"key":"a"}', recalled: true)), isNull);
      expect(ImageContent.of(_msg(msgVoice, '{"key":"a"}')), isNull);
      expect(ImageContent.of(_msg(msgImage, 'not json')), isNull);
    });

    test('bubble size keeps aspect within 260x320', () {
      expect(imageBubbleSize(1024, 768), (260.0, 195.0));
      expect(imageBubbleSize(768, 1024), (240.0, 320.0));
      expect(imageBubbleSize(100, 50), (100.0, 60.0)); // 不放大，最小 60
      expect(imageBubbleSize(0, 0), (200.0, 200.0));
      final (w, h) = imageBubbleSize(4000, 100);
      expect(w, 260.0);
      expect(h, 60.0);
    });
  });

  group('Presence / transcript / config', () {
    test('presence parses online and last_seen', () {
      final on = Presence.fromJson(jsonDecode('{"user_id":1,"online":true,"last_seen":null}'));
      expect(on.userId, 1);
      expect(on.online, isTrue);
      expect(on.lastSeen, isNull);
      final off = Presence.fromJson(jsonDecode('{"user_id":"2","online":false,"last_seen":"2026-10-15T06:03:00Z"}'));
      expect(off.userId, 2);
      expect(off.online, isFalse);
      expect(off.lastSeen!.toUtc(), DateTime.utc(2026, 10, 15, 6, 3));
    });

    test('transcript result', () {
      final r = TranscriptResult.fromJson(jsonDecode('{"text":"你好","cached":true}'));
      expect(r.text, '你好');
      expect(r.cached, isTrue);
    });

    test('config flags default off for old servers', () {
      final old = ClientConfig.fromJson(jsonDecode('{"recall_seconds":120,"voice_enabled":true}'));
      expect(old.imageEnabled, isFalse);
      expect(old.presenceEnabled, isFalse);
      expect(old.sttEnabled, isFalse);
      expect(old.imageMaxBytes, isNull);
      final cfg = ClientConfig.fromJson(jsonDecode(
          '{"image_enabled":true,"image_max_bytes":10485760,"presence_enabled":true,"stt_enabled":true}'));
      expect(cfg.imageEnabled, isTrue);
      expect(cfg.imageMaxBytes, 10485760);
      expect(cfg.presenceEnabled, isTrue);
      expect(cfg.sttEnabled, isTrue);
    });

    test('transcribe error messages', () {
      expect(transcribeError(ApiError(429, 'stt_limit', 'x')), '今日转文字次数已用完');
      expect(transcribeError(ApiError(501, 'stt_disabled', 'x')), '服务器未开启语音转文字');
      expect(transcribeError(ApiError(400, 'other', '自定义')), '自定义');
      expect(transcribeError(Exception('boom')), '转文字失败');
    });
  });

  group('util v0.3.0', () {
    test('previews', () {
      expect(previewOf(_msg(msgImage, '{}'), 1, (_) => 'x'), '[图片]');
      expect(previewOf(_msg(99, '{}'), 1, (_) => 'x'), unsupportedText);
      expect(unsupportedText, '[不支持的消息，请升级]');
      expect(shortPreview(_msg(msgImage, '{}')), '[图片]');
      expect(shortPreview(_msg(msgVoice, '{}')), '[语音]');
      expect(shortPreview(_msg(msgText, 'hi')), 'hi');
    });

    test('last seen text', () {
      final now = DateTime(2026, 10, 15, 18, 0);
      expect(lastSeenText(DateTime(2026, 10, 15, 14, 3), now), '最后在线 今天 14:03');
      expect(lastSeenText(DateTime(2026, 10, 14, 9, 5), now), '最后在线 昨天 09:05');
      expect(lastSeenText(null, now), '离线');
    });
  });

  group('theme seeds', () {
    test('8 seeds identical to web', () {
      expect(themeSeeds.map(seedToString).toList(),
          ['#6750A4', '#0061A4', '#006E1C', '#9C4146', '#8B5000', '#006A6A', '#7D5260', '#4A6363']);
    });

    test('parse', () {
      expect(parseSeed('system'), isNull);
      expect(parseSeed(null), isNull);
      expect(parseSeed('bogus'), isNull);
      expect(parseSeed('#0061A4')!.toARGB32(), 0xFF0061A4);
      expect(parseSeed('0061a4')!.toARGB32(), 0xFF0061A4);
    });

    test('tonal spot scheme builds for both brightness', () {
      final l = schemeFromSeed(themeSeeds[1], Brightness.light);
      final d = schemeFromSeed(themeSeeds[1], Brightness.dark);
      expect(l.brightness, Brightness.light);
      expect(d.brightness, Brightness.dark);
      expect(l.primary, isNot(d.primary));
    });
  });

  group('image prep', () {
    test('large opaque image is resized to 2048 long edge JPEG', () {
      final src = img.Image(width: 3000, height: 1500);
      img.fill(src, color: img.ColorRgb8(200, 100, 50));
      final out = prepareImageSync(img.encodePng(src));
      expect(out.mime, 'image/jpeg');
      expect(out.width, 2048);
      expect(out.height, 1024);
      final back = img.decodeJpg(out.bytes)!;
      expect(back.width, 2048);
      expect(back.height, 1024);
    });

    test('small JPEG stays the same size', () {
      final src = img.Image(width: 400, height: 300);
      final out = prepareImageSync(img.encodeJpg(src, quality: 95));
      expect(out.mime, 'image/jpeg');
      expect((out.width, out.height), (400, 300));
    });

    test('transparent PNG stays PNG', () {
      final src = img.Image(width: 64, height: 32, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(0, 0, 0, 0));
      final bytes = img.encodePng(src);
      final out = prepareImageSync(bytes);
      expect(out.mime, 'image/png');
      expect((out.width, out.height), (64, 32));
      expect(out.bytes, bytes);
    });

    test('GIF is passed through untouched', () {
      final src = img.Image(width: 30, height: 20);
      final bytes = img.encodeGif(src);
      final out = prepareImageSync(bytes);
      expect(out.mime, 'image/gif');
      expect((out.width, out.height), (30, 20));
      expect(out.bytes, bytes);
    });

    test('garbage throws', () {
      expect(() => prepareImageSync(Uint8List.fromList([1, 2, 3, 4])), throwsA(isA<ImagePrepException>()));
    });
  });

  group('ImageFileCache', () {
    test('put / find / adopt / delete', () async {
      final dir = await Directory.systemTemp.createTemp('imchat_img_test');
      final cache = await ImageFileCache.at(dir);
      expect(ImageFileCache.extFor('image/jpeg'), 'jpg');
      expect(ImageFileCache.extFor('image/gif'), 'gif');
      expect(ImageFileCache.extFor('application/x'), 'bin');
      expect(ImageFileCache.key(3, 9), '3:9');
      expect(await cache.find(3, 9), isNull);
      final f = await cache.put(3, 9, 'image/png', Uint8List.fromList([1, 2, 3]));
      expect(f.path.endsWith('3_9.png'), isTrue);
      expect((await cache.find(3, 9))!.path, f.path);
      final src = File('${dir.path}/tmp.jpg')..writeAsBytesSync([4, 5]);
      final a = await cache.adopt(3, 10, 'image/jpeg', src);
      expect(a.path.endsWith('3_10.jpg'), isTrue);
      expect(src.existsSync(), isFalse);
      await cache.delete(3, 9);
      await cache.delete(3, 10);
      expect(await cache.find(3, 9), isNull);
      expect(await cache.find(3, 10), isNull);
      await dir.delete(recursive: true);
    });
  });
}
