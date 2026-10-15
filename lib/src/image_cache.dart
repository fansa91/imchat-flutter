import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 图片本地永久缓存（与 [VoiceCache] 同样的写法）。
///
/// 文件保存在 `<documents>/IMChat/image/<服务器>/<会话ID>_<seq>.<ext>`，
/// 撤回 / 删除消息时同时删除本地文件。
class ImageFileCache {
  ImageFileCache(this._root);

  final Directory _root;

  static const _exts = ['jpg', 'png', 'webp', 'gif', 'bin'];

  static Future<ImageFileCache> open(String server) async {
    final docs = await getApplicationDocumentsDirectory();
    final host = server.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dir = Directory(p.join(docs.path, 'IMChat', 'image', host));
    await dir.create(recursive: true);
    return ImageFileCache(dir);
  }

  /// 测试用：指定目录
  static Future<ImageFileCache> at(Directory dir) async {
    await dir.create(recursive: true);
    return ImageFileCache(dir);
  }

  static String key(int cid, int seq) => '$cid:$seq';

  static String extFor(String mime) {
    final m = mime.split(';').first.trim().toLowerCase();
    return switch (m) {
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'bin',
    };
  }

  String _base(int cid, int seq) => '${cid}_$seq';

  Future<File?> find(int cid, int seq) async {
    final base = _base(cid, seq);
    for (final ext in _exts) {
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

  /// 把本地（已压缩的）待发送图片移入缓存，自己发的图片无需再下载
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
    for (final ext in _exts) {
      final f = File(p.join(_root.path, '$base.$ext'));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
