import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 全局唯一的语音播放器：同一时间只播放一条
class VoicePlayer extends ChangeNotifier {
  VoicePlayer() {
    _subs.add(_player.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
      notifyListeners();
    }));
    _subs.add(_player.onPositionChanged.listen((p) {
      _position = p;
      notifyListeners();
    }));
    _subs.add(_player.onPlayerComplete.listen((_) {
      _playing = false;
      _position = Duration.zero;
      _current = null;
      notifyListeners();
    }));
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];
  String? _current;
  bool _playing = false;
  Duration _position = Duration.zero;

  /// 正在播放（或暂停在）哪条：voiceKey 或 client_msg_id
  String? get current => _current;
  bool isPlaying(String id) => _current == id && _playing;
  Duration positionOf(String id) => _current == id ? _position : Duration.zero;

  Future<void> toggle(String id, File file) async {
    if (_current == id) {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
      return;
    }
    await _player.stop();
    _current = id;
    _position = Duration.zero;
    notifyListeners();
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> seek(String id, File file, Duration to) async {
    if (_current != id) {
      await toggle(id, file);
    }
    await _player.seek(to);
    _position = to;
    notifyListeners();
  }

  /// 撤回 / 删除时停止正在播放的这条
  Future<void> stopIf(String id) async {
    if (_current == id) {
      await _player.stop();
      _current = null;
      _playing = false;
      _position = Duration.zero;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
