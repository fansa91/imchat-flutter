import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 文件 / 视频消息的本地下载缓存（简化版，照 [VoiceCache]/[ImageFileCache] 的写法）。
///
/// 文件保存在 `<documents>/IMChat/<kind>/<服务器>/<会话ID>_<seq>.<ext>`，
/// kind 为 `file` 或 `video`。不做永久保留承诺：只按消息 key 落盘，
/// 撤回 / 删除时随消息一并清掉；不做严格 LRU（SPEC §2.4 的 500MB 上限
/// 以目录总量统计在 [totalBytes] 暴露给设置页展示，清理走 [prune] 粗略按旧文件删）。
class MediaFileCache {
  MediaFileCache(this._root);

  final Directory _root;

  static Future<MediaFileCache> open(String server, String kind) async {
    final docs = await getApplicationDocumentsDirectory();
    final host = server.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dir = Directory(p.join(docs.path, 'IMChat', kind, host));
    await dir.create(recursive: true);
    return MediaFileCache(dir);
  }

  /// 测试用：指定目录
  static Future<MediaFileCache> at(Directory dir) async {
    await dir.create(recursive: true);
    return MediaFileCache(dir);
  }

  static String key(int cid, int seq) => '$cid:$seq';

  static String extFor(String mime, [String name = '']) {
    final fromName = p.extension(name).replaceFirst('.', '').toLowerCase();
    if (fromName.isNotEmpty && fromName.length <= 10 && !fromName.contains(RegExp(r'[^a-z0-9]'))) return fromName;
    final m = mime.split(';').first.trim().toLowerCase();
    return switch (m) {
      'video/mp4' => 'mp4',
      'video/webm' => 'webm',
      'video/quicktime' => 'mov',
      'application/pdf' => 'pdf',
      'application/zip' => 'zip',
      'text/plain' => 'txt',
      _ => 'bin',
    };
  }

  String _base(int cid, int seq) => '${cid}_$seq';

  Future<File?> find(int cid, int seq) async {
    final base = _base(cid, seq);
    await for (final e in _root.list()) {
      if (e is File && p.basename(e.path).startsWith('$base.')) {
        if (await e.length() > 0) return e;
      }
    }
    return null;
  }

  Future<File> put(int cid, int seq, String mime, Uint8List bytes, [String name = '']) async {
    final f = File(p.join(_root.path, '${_base(cid, seq)}.${extFor(mime, name)}'));
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    return tmp.rename(f.path);
  }

  Future<File> adopt(int cid, int seq, String mime, File src, [String name = '']) async {
    final dst = p.join(_root.path, '${_base(cid, seq)}.${extFor(mime, name)}');
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
    await for (final e in _root.list()) {
      if (e is File && p.basename(e.path).startsWith('$base.')) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }

  Future<int> totalBytes() async {
    var sum = 0;
    await for (final e in _root.list()) {
      if (e is File) sum += await e.length();
    }
    return sum;
  }

  /// 超过 [maxBytes] 时按修改时间从旧到新删到达标为止（粗略 LRU）
  Future<void> prune(int maxBytes) async {
    final files = <File>[];
    await for (final e in _root.list()) {
      if (e is File) files.add(e);
    }
    var total = 0;
    final stats = <File, FileStat>{};
    for (final f in files) {
      final s = await f.stat();
      stats[f] = s;
      total += s.size;
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    for (final f in files) {
      if (total <= maxBytes) break;
      total -= stats[f]!.size;
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}
