import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 语音本地永久缓存。
///
/// 服务器上的语音只保留若干天（对象存储生命周期），客户端收到语音后立即下载，
/// 以 `会话ID_seq` 为文件名永久保存在应用文档目录 `voice/<服务器>/` 下，播放只用本地副本。
/// 撤回 / 删除消息时同时删除本地文件。
class VoiceCache {
  VoiceCache(this._root);

  final Directory _root;

  static Future<VoiceCache> open(String server) async {
    final docs = await getApplicationDocumentsDirectory();
    final host = server.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dir = Directory(p.join(docs.path, 'IMChat', 'voice', host));
    await dir.create(recursive: true);
    return VoiceCache(dir);
  }

  /// 测试用：指定目录
  static Future<VoiceCache> at(Directory dir) async {
    await dir.create(recursive: true);
    return VoiceCache(dir);
  }

  static String key(int cid, int seq) => '$cid:$seq';

  static String extFor(String mime) {
    final m = mime.split(';').first.trim().toLowerCase();
    return switch (m) {
      'audio/webm' => 'webm',
      'audio/ogg' => 'ogg',
      'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' => 'm4a',
      'audio/aac' => 'aac',
      'audio/mpeg' => 'mp3',
      _ => 'bin',
    };
  }

  String _base(int cid, int seq) => '${cid}_$seq';

  /// 找到已缓存的文件（不同扩展名都算）
  Future<File?> find(int cid, int seq) async {
    final base = _base(cid, seq);
    for (final ext in const ['m4a', 'webm', 'ogg', 'aac', 'mp3', 'bin']) {
      final f = File(p.join(_root.path, '$base.$ext'));
      if (await f.exists() && await f.length() > 0) return f;
    }
    return null;
  }

  Future<File> put(int cid, int seq, String mime, Uint8List bytes) async {
    final f = File(p.join(_root.path, '${_base(cid, seq)}.${extFor(mime)}'));
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    return tmp.rename(f.path);
  }

  /// 把本地录音文件移入缓存（自己发的语音，无需再下载）
  Future<File> adopt(int cid, int seq, String mime, File src) async {
    final dst = p.join(_root.path, '${_base(cid, seq)}.${extFor(mime)}');
    try {
      return await src.rename(dst);
    } catch (_) {
      final f = await src.copy(dst);
      try {
        await src.delete();
      } catch (_) {}
      return f;
    }
  }

  Future<void> delete(int cid, int seq) async {
    final base = _base(cid, seq);
    for (final ext in const ['m4a', 'webm', 'ogg', 'aac', 'mp3', 'bin']) {
      final f = File(p.join(_root.path, '$base.$ext'));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
