import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/history_db.dart';
import '../models.dart';
import '../services/localai_client.dart';
import 'settings.dart';

const _uuid = Uuid();

class ChatController extends ChangeNotifier {
  final HistoryDb db;
  final Settings settings;
  final LocalAIClient client;

  bool online = false;
  List<String> models = [];
  List<Conversation> conversations = [];
  Conversation? current;
  List<ChatMessage> messages = [];
  bool busy = false;
  String? error;
  StreamSubscription<String>? _sub;
  Timer? _pingTimer;

  ChatController(this.db, this.settings)
      : client = LocalAIClient(baseUrl: settings.baseUrl, apiKey: settings.apiKey);

  Future<void> init() async {
    await refreshConversations();
    await checkConnection();
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) => checkConnection());
  }

  /// Connects to LocalAI only if it is started.
  Future<void> checkConnection() async {
    client
      ..baseUrl = settings.baseUrl
      ..apiKey = settings.apiKey;
    final ok = await client.ping();
    if (ok && (!online || models.isEmpty)) {
      try {
        models = await client.listModels();
        if (settings.chatModel.isEmpty && models.isNotEmpty) {
          settings.chatModel = models.first;
          await settings.save();
        }
      } catch (_) {}
    }
    if (ok != online) {
      online = ok;
      notifyListeners();
    } else if (ok) {
      notifyListeners();
    }
  }

  Future<void> refreshConversations([String? search]) async {
    conversations = await db.conversations(search: search);
    notifyListeners();
  }

  void newConversation() {
    stop();
    current = null;
    messages = [];
    error = null;
    notifyListeners();
  }

  Future<void> open(Conversation c) async {
    stop();
    current = c;
    messages = await db.messages(c.id);
    error = null;
    notifyListeners();
  }

  Future<void> delete(Conversation c) async {
    await db.deleteConversation(c.id);
    if (current?.id == c.id) newConversation();
    await refreshConversations();
  }

  Future<void> rename(Conversation c, String title) async {
    c.title = title;
    await db.saveConversation(c);
    await refreshConversations();
  }

  Future<Conversation> _ensureConversation(String firstText) async {
    if (current != null) return current!;
    final title = firstText.trim().isEmpty
        ? 'Nouvelle conversation'
        : firstText.trim().split('\n').first;
    current = Conversation(
        id: _uuid.v4(),
        title: title.length > 50 ? '${title.substring(0, 50)}…' : title,
        model: settings.chatModel);
    await db.saveConversation(current!);
    return current!;
  }

  Future<void> _add(ChatMessage m) async {
    messages.add(m);
    final c = current!;
    c.updatedAt = DateTime.now();
    await db.saveMessage(c.id, m);
    await db.saveConversation(c);
  }

  Future<void> send(String text, List<Attachment> attachments) async {
    if (busy || (text.trim().isEmpty && attachments.isEmpty)) return;
    if (!online) {
      error = 'LocalAI n\'est pas démarré (${settings.baseUrl}).';
      notifyListeners();
      return;
    }
    error = null;
    await _ensureConversation(text);
    await _add(ChatMessage(id: _uuid.v4(), role: 'user', content: text, attachments: attachments));
    await _complete();
  }

  /// Regenerates the last assistant answer.
  Future<void> regenerate() async {
    if (busy || messages.isEmpty) return;
    if (messages.last.role == 'assistant') messages.removeLast();
    await _complete();
  }

  Future<void> _complete() async {
    final history = messages.where((m) => m.role != 'system').toList();
    final reply = ChatMessage(id: _uuid.v4(), role: 'assistant', content: '');
    messages.add(reply);
    busy = true;
    notifyListeners();
    final done = Completer<void>();
    _sub = client
        .chatStream(
          model: settings.chatModel,
          messages: history,
          systemPrompt: settings.systemPrompt,
          temperature: settings.temperature,
        )
        .listen((t) {
      reply.content += t;
      notifyListeners();
    }, onError: (Object e) {
      error = e.toString();
      if (!done.isCompleted) done.complete();
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, cancelOnError: true);
    await done.future;
    await _finish(reply);
  }

  Future<void> _finish(ChatMessage reply) async {
    _sub = null;
    busy = false;
    if (reply.content.isEmpty) {
      messages.remove(reply);
    } else {
      final c = current!;
      c.updatedAt = DateTime.now();
      await db.saveMessage(c.id, reply);
      await db.saveConversation(c);
    }
    await refreshConversations();
  }

  void stop() {
    _sub?.cancel();
    if (_sub != null && busy && messages.isNotEmpty) {
      _finish(messages.last);
    }
  }

  /// Generates an image from a prompt and stores it in the conversation.
  Future<void> generateImage(String prompt) async {
    if (busy || prompt.trim().isEmpty) return;
    if (!online) {
      error = 'LocalAI n\'est pas démarré.';
      notifyListeners();
      return;
    }
    error = null;
    await _ensureConversation(prompt);
    await _add(ChatMessage(id: _uuid.v4(), role: 'user', content: '🎨 $prompt'));
    busy = true;
    notifyListeners();
    try {
      final imgs = await client.generateImage(prompt, model: settings.imageModel);
      await _add(ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: 'Image générée :',
        attachments: imgs
            .map((b) => Attachment(
                kind: AttachmentKind.image, name: 'image.png', mime: 'image/png', data: b))
            .toList(),
      ));
    } catch (e) {
      error = e.toString();
    }
    busy = false;
    await refreshConversations();
  }

  Future<String> transcribe(Uint8List audio, String filename) =>
      client.transcribe(audio, filename, model: settings.sttModel);

  Future<Uint8List> speak(String text) =>
      client.speak(text, model: settings.ttsModel, voice: settings.ttsVoice);

  String exportCurrent() => const JsonEncoder.withIndent('  ').convert({
        'title': current?.title,
        'messages': messages.map((m) => {'role': m.role, 'content': m.content}).toList(),
      });

  @override
  void dispose() {
    _pingTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
