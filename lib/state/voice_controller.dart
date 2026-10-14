import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:record/record.dart';

import '../models.dart';
import '../services/voice_audio.dart';
import 'chat_controller.dart';
import 'settings.dart';

/// Style oral: appended to the user's system prompt in the Mode vocal.
const oralStyle = 'Cette conversation est vocale : ta réponse sera lue à voix haute. '
    'Réponds en phrases courtes et naturelles, comme à l\'oral, sans Markdown, '
    'listes, tableaux, emojis ni code.';

// ponytail: French only; follow sttLanguage if other languages are needed.
const _signalPhrases = ['Hmm…', 'D\'accord…', 'Voyons…', 'Alors…', 'Je regarde ça.'];

enum VoicePhase { listening, thinking, speaking, error }

/// Runs in the foreground service isolate and only relays notification
/// buttons; the voice loop itself stays in the main isolate.
@pragma('vm:entry-point')
void voiceServiceCallback() => FlutterForegroundTask.setTaskHandler(_ButtonRelay());

class _ButtonRelay extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) => FlutterForegroundTask.sendDataToMain(id);
}

/// The assistant's Tour being generated and spoken.
class _Reply {
  final sentences = <String>[];
  final spoken = <String>[];
  final audio = <int, Future<Uint8List?>>{};
  String pending = '';
  String? ttsError;
  bool done = false, interrupted = false, signalDecided = false;
  var _changed = Completer<void>();

  Future<void> get changed => _changed.future;

  void notify() {
    _changed.complete();
    _changed = Completer<void>();
  }
}

/// Mode vocal: continuous listening, Tours, Interruptions, Signal d'écoute.
class VoiceController extends ChangeNotifier {
  final ChatController chat;
  final Settings settings;

  VoiceController(this.chat, this.settings);

  final _rec = AudioRecorder();
  final _player = AudioPlayer();
  final _signalPlayer = AudioPlayer();
  final _vad = Vad();
  final _signal = ListeningSignal();
  static final _clipCache = <String, List<Uint8List>>{};

  VoicePhase phase = VoicePhase.listening;
  bool muted = false;
  bool closed = false;
  bool _disposed = false;

  /// 0..1, drives the Orbe: mic while listening, assistant voice while speaking.
  double level = 0;

  /// Rappel: the user's last transcribed sentence, shown for a few seconds.
  String? heard;
  String? error;

  StreamSubscription<Uint8List>? _mic;
  Timer? _ticker, _heardTimer;
  final _preRoll = <Uint8List>[];
  BytesBuilder? _utterance;
  Uint8List? _pendingPcm, _carry;
  int _turn = 0;
  _Reply? _reply;
  bool _playing = false;
  List<double> _env = const [];
  final _playClock = Stopwatch();
  Future<void>? _signalDone;

  String get _clipKey => '${settings.ttsModel}|${settings.ttsVoice}';
  List<Uint8List> get _clips => _clipCache[_clipKey] ?? const [];

  String get statusText => muted
      ? 'Micro coupé'
      : switch (phase) {
          VoicePhase.listening => 'À l\'écoute',
          VoicePhase.thinking => 'Réflexion…',
          VoicePhase.speaking => 'Chat It parle',
          VoicePhase.error => error ?? 'Erreur',
        };

  Future<void> start() async {
    // Android 14 only allows a microphone service once the permission is granted.
    if (!await _rec.hasPermission()) return _fail('Permission micro refusée');
    await _startService();
    final ctx = AudioContext(
        android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      audioMode: AndroidAudioMode.inCommunication,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.voiceCommunication,
      audioFocus: AndroidAudioFocus.none,
    ));
    await _player.setAudioContext(ctx);
    await _signalPlayer.setAudioContext(ctx);
    if (closed) return;
    // ponytail: voiceCommunication source + in-communication mode is what makes
    // Android's echo canceller hear the TTS; untested beyond one config.
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: voiceSampleRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      audioInterruption: AudioInterruptionMode.none,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
        audioManagerMode: AudioManagerMode.modeInCommunication,
        speakerphone: true,
      ),
    ));
    if (closed) return;
    _mic = stream.listen(_onPcm);
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    if (!chat.online) _fail(chat.offlineMessage());
  }

  Future<void> _startService() async {
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'voice_mode', channelName: 'Mode vocal', onlyAlertOnce: true),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true, // LocalAI is on the LAN: keep Wi-Fi up screen off.
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onButton);
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Chat It — Mode vocal',
      notificationText: statusText,
      notificationButtons: _buttons,
      callback: voiceServiceCallback,
    );
  }

  List<NotificationButton> get _buttons => [
        NotificationButton(id: 'mute', text: muted ? 'Réactiver le micro' : 'Couper le micro'),
        const NotificationButton(id: 'quit', text: 'Quitter'),
      ];

  void _onButton(Object id) {
    if (id == 'mute') toggleMute();
    if (id == 'quit') stop();
  }

  void _syncNotification() {
    if (closed) return;
    FlutterForegroundTask.updateService(notificationText: statusText, notificationButtons: _buttons);
  }

  void _setPhase(VoicePhase p) {
    if (phase == p && p != VoicePhase.error) return;
    phase = p;
    _syncNotification();
    notifyListeners();
  }

  void _fail(String message) {
    error = message;
    _setPhase(VoicePhase.error);
  }

  void _onPcm(Uint8List chunk) {
    if (closed || muted) return;
    final ms = chunk.length ~/ (voiceSampleRate * 2 ~/ 1000);
    final db = pcmLevelDb(chunk);
    if (!_playing) level = orbLevel(db);
    final event = _vad.feed(db, ms, playing: _playing);
    if (event == VadEvent.speechStart) {
      _interrupt();
      _utterance = BytesBuilder(copy: false);
      if (_carry != null) _utterance!.add(_carry!);
      _carry = null;
      _preRoll.forEach(_utterance!.add);
      _preRoll.clear();
      error = null;
      _setPhase(VoicePhase.listening);
    }
    if (_utterance != null) {
      _utterance!.add(chunk);
    } else {
      _preRoll.add(chunk);
      var kept = _preRoll.fold(0, (n, c) => n + c.length);
      while (_preRoll.length > 1 && kept > preRollMs * voiceSampleRate * 2 ~/ 1000) {
        kept -= _preRoll.removeAt(0).length;
      }
    }
    if (event == VadEvent.speechEnd) {
      final pcm = _utterance!.takeBytes();
      _utterance = null;
      _onUtterance(pcm);
    }
  }

  /// The user spoke over the assistant (or over a Tour still being handled).
  void _interrupt() {
    _turn++;
    // Speech not transcribed yet is merged into the next Tour, not lost.
    if (_pendingPcm != null) _carry = _pendingPcm;
    _pendingPcm = null;
    final r = _reply;
    if (r != null) {
      r.interrupted = true;
      r.notify();
    }
    chat.stop();
    _player.stop();
    _signalPlayer.stop();
    _playing = false;
  }

  Future<void> _onUtterance(Uint8List pcm) async {
    final turn = ++_turn;
    _pendingPcm = pcm;
    _setPhase(VoicePhase.thinking);
    final String text;
    try {
      text = await chat.transcribe(pcmToWav(pcm), 'voice.wav');
    } catch (e) {
      if (turn == _turn) {
        _pendingPcm = null;
        _fail('Transcription : $e');
      }
      return;
    }
    if (turn != _turn || closed) return;
    _pendingPcm = null;
    if (isNoiseTranscript(text)) return _setPhase(VoicePhase.listening);
    _showHeard(text);
    await _respond(turn, text);
  }

  Future<void> _respond(int turn, String text) async {
    if (!chat.online) return _fail(chat.offlineMessage());
    final r = _reply = _Reply();
    Timer(listeningSignalDelay, () {
      if (turn == _turn) _decideSignal(r, late: true);
    });
    final sending = chat.send(text, const [], extraSystem: oralStyle, onToken: (t) {
      final (sentences, rest) = takeSentences(r.pending + t);
      r.pending = rest;
      r.sentences.addAll(sentences.map(speakable).where((s) => s.isNotEmpty));
      r.notify();
    }).whenComplete(() {
      final tail = speakable(r.pending);
      if (tail.isNotEmpty) r.sentences.add(tail);
      r.done = true;
      r.notify();
    });
    await _speakAll(turn, r);
    final ChatMessage? reply = await sending;
    if (_reply == r) _reply = null;
    if (reply != null && r.interrupted) {
      await chat.trimReply(reply, r.spoken.isEmpty ? '' : '${r.spoken.join(' ')} … _(interrompu)_');
    }
    if (turn != _turn || closed) return;
    if (r.ttsError != null) return _fail('Synthèse vocale : ${r.ttsError}');
    if (reply == null && chat.error != null) return _fail(chat.error!);
    // After the first reply, so these TTS calls never delay a Tour on a one-GPU server.
    _prepareSignals();
    _setPhase(VoicePhase.listening);
  }

  /// Plays sentences as they arrive, fetching sentence N+1 while N plays.
  Future<void> _speakAll(int turn, _Reply r) async {
    var i = 0;
    while (turn == _turn && !closed) {
      if (i >= r.sentences.length) {
        if (r.done) return;
        await r.changed;
        continue;
      }
      final next = _tts(r, i);
      _tts(r, i + 1);
      final audio = await next;
      if (turn != _turn || closed) return;
      if (audio == null) return;
      _decideSignal(r, late: false);
      await _signalDone;
      if (turn != _turn || closed) return;
      r.spoken.add(r.sentences[i]);
      _setPhase(VoicePhase.speaking);
      await _play(_player, audio);
      i++;
    }
  }

  Future<Uint8List?> _tts(_Reply r, int i) {
    if (i >= r.sentences.length) return Future.value();
    return r.audio.putIfAbsent(
        i,
        () => chat.speak(r.sentences[i]).then<Uint8List?>((b) => b, onError: (Object e) {
              r.ttsError ??= '$e';
              return null;
            }));
  }

  void _decideSignal(_Reply r, {required bool late}) {
    if (r.signalDecided) return;
    r.signalDecided = true;
    final i = _signal.next(late: late, clips: _clips.length);
    _signalDone = i == null ? null : _play(_signalPlayer, _clips[i]);
  }

  Future<void> _play(AudioPlayer p, Uint8List audio) async {
    _env = wavEnvelope(audio);
    _playClock
      ..reset()
      ..start();
    _playing = true;
    final end = p.onPlayerStateChanged
        .firstWhere((s) => s == PlayerState.completed || s == PlayerState.stopped)
        .timeout(const Duration(minutes: 2), onTimeout: () => PlayerState.stopped);
    try {
      await p.play(BytesSource(audio));
      await end;
    } catch (_) {}
    _playing = false;
  }

  void _tick() {
    if (_playing) {
      final ms = _playClock.elapsedMilliseconds;
      final i = ms ~/ 50;
      // Non-WAV TTS output has no envelope: fall back to a soft pulse.
      level = _env.isEmpty ? 0.45 + 0.25 * sin(ms / 90) : (i < _env.length ? _env[i] : 0);
    }
    notifyListeners();
  }

  void _showHeard(String text) {
    heard = text;
    _heardTimer?.cancel();
    _heardTimer = Timer(const Duration(seconds: 3), () {
      heard = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Pre-synthesizes the Signal d'écoute clips with the current voice, once per voice.
  Future<void> _prepareSignals() async {
    final key = _clipKey;
    if (_clipCache.containsKey(key)) return;
    final clips = _clipCache[key] = <Uint8List>[];
    for (final phrase in _signalPhrases) {
      if (closed) break;
      try {
        clips.add(await chat.speak(phrase));
      } catch (_) {
        break;
      }
    }
    // Retry next time if incomplete (server off, voice missing, closed early).
    if (clips.length < _signalPhrases.length) _clipCache.remove(key);
  }

  Future<void> toggleMute() async {
    muted = !muted;
    if (muted) {
      _vad.reset();
      _utterance = null;
      level = 0;
      await _rec.pause();
    } else {
      await _rec.resume();
    }
    _syncNotification();
    notifyListeners();
  }

  Future<void>? _stopping;

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _interrupt();
    closed = true;
    _ticker?.cancel();
    _heardTimer?.cancel();
    await _mic?.cancel();
    await _rec.stop();
    // audioplayers sets the audio mode globally, and record restores the mode
    // it found (already in-communication): put the phone back to normal.
    await _player.setAudioContext(AudioContext());
    FlutterForegroundTask.removeTaskDataCallback(_onButton);
    await FlutterForegroundTask.stopService();
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop().whenComplete(() {
      _rec.dispose();
      _player.dispose();
      _signalPlayer.dispose();
    });
    super.dispose();
  }
}
