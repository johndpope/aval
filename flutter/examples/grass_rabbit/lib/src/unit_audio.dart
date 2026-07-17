/// Per-unit AAC clips extracted from the mansion master timeline, played in
/// lockstep with graph unit switches. The compiled `.avl` is video-only; audio
/// lives beside it as Flutter assets.
///
/// Exactly **one** clip plays at a time. Unit switches fully tear down the
/// previous `AudioPlayer` so a looping idle ambient track cannot keep running
/// under a spoken "hi"/"great" line (just_audio loop + setAsset races on macOS).
library;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the AAC clip for the unit currently on screen.
///
/// Asset layout (from `motion.json` source ranges @ 24 fps):
/// - `idle-loop` → frames [0, 240) → 0–10s
/// - `hi`        → frames [240, 480) → 10–20s
/// - `great`     → frames [480, 720) → 20–30s
class UnitAudioPlayer {
  UnitAudioPlayer();

  AudioPlayer _player = AudioPlayer();
  String? _unitId;
  bool _sessionReady = false;

  /// Bumped on every [playUnit]/stop]/dispose] so in-flight async work bails out.
  int _generation = 0;

  static const Map<String, String> _assetForUnit = <String, String>{
    'idle-loop': 'assets/audio/idle-loop.m4a',
    'hi': 'assets/audio/hi.m4a',
    'great': 'assets/audio/great.m4a',
  };

  Future<void> _ensureSession() async {
    if (_sessionReady) return;
    final session = await AudioSession.instance;
    // Exclusive playback — do not mix with other sessions or leftover streams.
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.movie,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
    ));
    await session.setActive(true);
    _sessionReady = true;
  }

  /// Hard-stop: disable loop, stop, dispose player, create a fresh one.
  /// Guarantees no ambient loop can keep feeding the audio device.
  Future<void> _resetPlayer() async {
    final old = _player;
    _player = AudioPlayer();
    try {
      await old.setLoopMode(LoopMode.off);
    } catch (_) {}
    try {
      await old.stop();
    } catch (_) {}
    try {
      await old.dispose();
    } catch (_) {}
  }

  /// Starts (or switches to) the clip for [unitId]. Looping units loop audio;
  /// finite units play once and then silence.
  Future<void> playUnit(String unitId, {required bool loop}) async {
    final gen = ++_generation;

    final asset = _assetForUnit[unitId];
    if (asset == null) {
      await stop();
      return;
    }

    // Already on this unit and still playing — do not restart (keeps idle loop
    // seamless across brief false unit re-entries).
    if (_unitId == unitId && _player.playing) {
      return;
    }

    final previous = _unitId;
    try {
      await _ensureSession();
      if (gen != _generation) return;

      // Always tear down the previous player when the unit changes so a looping
      // idle clip cannot mix under the next unit's audio.
      if (previous != unitId) {
        await _resetPlayer();
        if (gen != _generation) return;
      }

      _unitId = unitId;
      await _player.setLoopMode(loop ? LoopMode.one : LoopMode.off);
      if (gen != _generation) return;
      await _player.setAsset(asset);
      if (gen != _generation) return;
      await _player.setVolume(1.0);
      await _player.seek(Duration.zero);
      if (gen != _generation) return;
      await _player.play();
      if (gen != _generation) {
        // A newer request won the race — stop this player.
        try {
          await _player.stop();
        } catch (_) {}
        return;
      }
      debugPrint('[audio] $previous → $unitId (loop=$loop)');
    } catch (e, st) {
      if (gen == _generation) {
        debugPrint('[audio] play failed for $unitId: $e\n$st');
      }
    }
  }

  Future<void> stop() async {
    _generation++;
    _unitId = null;
    await _resetPlayer();
  }

  Future<void> dispose() async {
    _generation++;
    _unitId = null;
    try {
      await _player.setLoopMode(LoopMode.off);
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
  }

  String? get currentUnitId => _unitId;
}
