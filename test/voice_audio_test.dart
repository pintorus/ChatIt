import 'dart:math';
import 'dart:typed_data';

import 'package:chatit/services/voice_audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ms] of a 200 Hz sine at [amp] (0..1), PCM16 mono 16 kHz.
Uint8List tone(int ms, double amp) {
  final n = voiceSampleRate * ms ~/ 1000;
  final d = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    d.setInt16(i * 2, (amp * 32767 * sin(2 * pi * 200 * i / voiceSampleRate)).round(), Endian.little);
  }
  return d.buffer.asUint8List();
}

void main() {
  test('VAD: Tour starts on speech, ends on silence, ignores echo-level sound', () {
    final vad = Vad();
    final quiet = pcmLevelDb(tone(20, 0.002));
    final voice = pcmLevelDb(tone(20, 0.3));
    final echo = pcmLevelDb(tone(20, 0.01));
    final events = <VadEvent>[];
    void feed(double db, int ms, {bool playing = false}) {
      for (var t = 0; t < ms; t += 20) {
        final e = vad.feed(db, 20, playing: playing);
        if (e != VadEvent.none) events.add(e);
      }
    }

    feed(quiet, 1000);
    feed(echo, 1000, playing: true); // residual TTS echo: no Interruption
    expect(events, isEmpty);
    feed(voice, 400);
    expect(events, [VadEvent.speechStart]);
    feed(quiet, endSilenceMs + 40);
    expect(events, [VadEvent.speechStart, VadEvent.speechEnd]);
  });

  test('WAV header and envelope round-trip', () {
    final wav = pcmToWav(tone(500, 0.3));
    expect(wav.length, 44 + 16000);
    expect(String.fromCharCodes(wav, 8, 12), 'WAVE');
    final env = wavEnvelope(wav);
    expect(env.length, 10);
    expect(env.every((l) => l > 0.5), isTrue);
    expect(wavEnvelope(Uint8List.fromList([1, 2, 3])), isEmpty);
  });

  test('sentences are split off streamed text', () {
    final (s, rest) = takeSentences('Bonjour ! Il fait 3.5 degrés. Et dem');
    expect(s, ['Bonjour !', 'Il fait 3.5 degrés.']);
    expect(rest, 'Et dem');
    expect(speakable('**Oui**, `code` # titre'), 'Oui, code  titre');
    expect(isNoiseTranscript('Sous-titrage ST\' 501'), isTrue);
    expect(isNoiseTranscript('[BLANK_AUDIO]'), isTrue);
    expect(isNoiseTranscript('Quelle heure est-il ?'), isFalse);
  });

  test("Signal d'écoute: only when late, never two Tours in a row nor same clip twice", () {
    final sig = ListeningSignal(Random(1));
    expect(sig.next(late: false, clips: 3), isNull);
    final a = sig.next(late: true, clips: 3);
    expect(a, isNotNull);
    expect(sig.next(late: true, clips: 3), isNull); // previous Tour had one
    final b = sig.next(late: true, clips: 3);
    expect(b, isNotNull);
    expect(b, isNot(a));
    expect(ListeningSignal().next(late: true, clips: 0), isNull);
  });
}
