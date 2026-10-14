import 'dart:math';
import 'dart:typed_data';

// ponytail: VAD and timing knobs guessed, not measured. Calibrate on the real
// phone (mic gain, echo cancellation quality, room noise).
const voiceSampleRate = 16000;

/// dB above the noise floor that counts as speech while the assistant is silent.
const speechMarginDb = 12.0;

/// Same, while assistant audio plays: residual echo must not trigger an Interruption.
const bargeInMarginDb = 22.0;

/// Loud time needed to start a Tour (shorter = noise, clicks).
const minSpeechMs = 300;

/// Silence that ends the user's Tour.
const endSilenceMs = 800;

/// Audio kept from just before speech was detected, so first syllables survive.
const preRollMs = 300;

/// Signal d'écoute only if the reply hasn't started this long after the Tour.
const listeningSignalDelay = Duration(seconds: 1);

/// dBFS level of a PCM16 little-endian chunk.
double pcmLevelDb(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final n = pcm.length ~/ 2;
  if (n == 0) return -100;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = data.getInt16(i * 2, Endian.little);
    sum += s * s;
  }
  final rms = sqrt(sum / n);
  return rms < 1 ? -100 : 20 * log(rms / 32768) / ln10;
}

/// Maps a dBFS level to 0..1 for the Orbe.
double orbLevel(double db) => ((db + 55) / 40).clamp(0.0, 1.0);

enum VadEvent { none, speechStart, speechEnd }

/// Energy-based voice activity detection with an adaptive noise floor.
class Vad {
  double floor = -50;
  bool speaking = false;
  int _loudMs = 0;
  int _quietMs = 0;

  /// Feeds one mic chunk of [ms] milliseconds at [db] dBFS. [playing] is true
  /// while assistant audio is audible, which raises the threshold.
  VadEvent feed(double db, int ms, {bool playing = false}) {
    final loud = db > floor + (playing ? bargeInMarginDb : speechMarginDb);
    if (!speaking) {
      // Track the floor only on quiet, echo-free audio.
      if (!loud && !playing) {
        floor = (floor + (db - floor) * (db < floor ? 0.3 : 0.02)).clamp(-65.0, -25.0);
      }
      _loudMs = loud ? _loudMs + ms : 0;
      if (_loudMs < minSpeechMs) return VadEvent.none;
      speaking = true;
      _quietMs = 0;
      return VadEvent.speechStart;
    }
    _quietMs = loud ? 0 : _quietMs + ms;
    if (_quietMs < endSilenceMs) return VadEvent.none;
    reset();
    return VadEvent.speechEnd;
  }

  void reset() {
    speaking = false;
    _loudMs = 0;
    _quietMs = 0;
  }
}

/// Wraps mono PCM16 in a WAV container for `/v1/audio/transcriptions`.
Uint8List pcmToWav(Uint8List pcm, {int sampleRate = voiceSampleRate}) {
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // mono
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(h.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}

/// Loudness (0..1) of a PCM16 WAV every [stepMs], to animate the Orbe while
/// the assistant speaks. Empty when the bytes are not PCM16 WAV.
List<double> wavEnvelope(Uint8List wav, {int stepMs = 50}) {
  if (wav.length < 44 || String.fromCharCodes(wav, 0, 4) != 'RIFF') return const [];
  final d = ByteData.sublistView(wav);
  var pos = 12, channels = 1, rate = 0, bits = 0;
  while (pos + 8 <= wav.length) {
    final id = String.fromCharCodes(wav, pos, pos + 4);
    final size = d.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      if (d.getUint16(body, Endian.little) != 1) return const [];
      channels = d.getUint16(body + 2, Endian.little);
      rate = d.getUint32(body + 4, Endian.little);
      bits = d.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (bits != 16 || rate == 0) return const [];
      final end = min(body + size, wav.length);
      final step = rate * channels * 2 * stepMs ~/ 1000;
      return [
        for (var at = body; at + 2 <= end; at += step)
          orbLevel(pcmLevelDb(Uint8List.sublistView(wav, at, min(at + step, end) & ~1))),
      ];
    }
    pos = body + size + (size & 1);
  }
  return const [];
}

final _boundary = RegExp(r'[.!?…]+["»)\]]*\s|\n');

/// Splits complete sentences off streamed text; returns them and the unfinished rest.
(List<String>, String) takeSentences(String text) {
  final out = <String>[];
  var start = 0;
  for (final m in _boundary.allMatches(text)) {
    final s = text.substring(start, m.end).trim();
    if (s.isNotEmpty) out.add(s);
    start = m.end;
  }
  return (out, text.substring(start));
}

/// Strips Markdown symbols the Style oral prompt may not have prevented.
String speakable(String s) => s.replaceAll(RegExp(r'[*_#`>|]|^\s*[-•]\s+', multiLine: true), '').trim();

const _whisperNoise = ['sous-titr', "merci d'avoir regardé", 'amara.org', 'abonnez-vous'];

/// Whisper output that is noise or a known hallucination on near-silence.
bool isNoiseTranscript(String t) {
  final s = t.trim().toLowerCase();
  return s.isEmpty ||
      RegExp(r'^[\[(].*[\])]$').hasMatch(s) ||
      _whisperNoise.any(s.contains);
}

/// Signal d'écoute rule: only when the reply is late, never two Tours in a
/// row, never the same clip twice in a row.
class ListeningSignal {
  final Random _rng;
  bool _previousTour = false;
  int? _lastClip;

  ListeningSignal([Random? rng]) : _rng = rng ?? Random();

  /// Called once per Tour. Returns the clip to play, or null.
  int? next({required bool late, required int clips}) {
    if (!late || clips == 0 || _previousTour) {
      _previousTour = false;
      return null;
    }
    var i = _rng.nextInt(clips);
    if (clips > 1 && i == _lastClip) i = (i + 1) % clips;
    _lastClip = i;
    _previousTour = true;
    return i;
  }
}
