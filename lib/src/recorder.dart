import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// 一段录音结果
class Recording {
  final File file;
  final String mime; // 基础 MIME，不含 codecs
  final int durationMs;
  final int size;
  final List<int> waveform;
  const Recording({
    required this.file,
    required this.mime,
    required this.durationMs,
    required this.size,
    required this.waveform,
  });
}

/// 录音器：AAC-LC / m4a（audio/mp4），所有平台都支持且服务器接受。
/// 开始后实时回调电平（0~1），stop() 返回结果，cancel() 丢弃。
class VoiceRecorder {
  VoiceRecorder(this.maxMs);

  final int maxMs;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _autoStop;
  final List<double> _levels = [];
  DateTime? _started;
  String? _path;
  bool _finished = false;

  void Function(double level, int elapsedMs) onLevel = (_, _) {};
  void Function() onAutoStop = () {};

  int get elapsed => _started == null ? 0 : DateTime.now().difference(_started!).inMilliseconds;

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    if (!await _rec.hasPermission()) {
      throw const RecorderException('permission');
    }
    final tmp = await getTemporaryDirectory();
    _path = p.join(tmp.path, 'rec_${const Uuid().v4()}.m4a');
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 48000,
        sampleRate: 44100,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: _path!,
    );
    _started = DateTime.now();
    _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 80)).listen((a) {
      // current 为 dBFS（-160 ~ 0），映射到 0~1
      final db = a.current.isFinite ? a.current : -160.0;
      final level = ((db + 50) / 50).clamp(0.0, 1.0);
      _levels.add(level);
      onLevel(level, elapsed);
    });
    _autoStop = Timer(Duration(milliseconds: maxMs), () => onAutoStop());
  }

  Future<Recording?> stop() async {
    if (_finished) return null;
    _finished = true;
    final durationMs = min(maxMs, elapsed);
    _cleanupTimers();
    String? out;
    try {
      out = await _rec.stop();
    } catch (_) {}
    await _rec.dispose();
    final path = out ?? _path;
    if (path == null) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    final size = await f.length();
    if (size == 0) {
      await f.delete();
      return null;
    }
    return Recording(
      file: f,
      mime: 'audio/mp4',
      durationMs: durationMs,
      size: size,
      waveform: downsample(_levels, 40),
    );
  }

  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    _cleanupTimers();
    try {
      await _rec.cancel();
    } catch (_) {}
    await _rec.dispose();
    if (_path != null) {
      try {
        final f = File(_path!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  void _cleanupTimers() {
    _autoStop?.cancel();
    _ampSub?.cancel();
  }
}

class RecorderException implements Exception {
  final String code;
  const RecorderException(this.code);
}

/// 把电平序列压缩成 n 个 6~100 的整数（与 web 的 downsample 一致）
List<int> downsample(List<double> levels, int n) {
  if (levels.isEmpty) return List.filled(n, 8);
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    final a = (i * levels.length) ~/ n;
    final b = max(a + 1, ((i + 1) * levels.length) ~/ n);
    var m = 0.0;
    for (var j = a; j < b && j < levels.length; j++) {
      m = max(m, levels[j]);
    }
    out.add(max(6, (m * 100).round()));
  }
  return out;
}

String fmtDuration(int ms) {
  final s = max(0, (ms / 1000).round());
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
