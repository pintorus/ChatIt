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

  ServerState state = ServerState.offline;
  AuthStatus auth = AuthStatus.none;
  bool get online => state == ServerState.ready;
  List<String> models = [];
  List<Conversation> conversations = [];
  Conversation? current;
  List<ChatMessage> messages = [];
  bool busy = false;
  String? error;
  StreamSubscription<String>? _sub;
  Completer<void>? _done;
  Timer? _pingTimer;

  ChatController(this.db, this.settings)
      : client = LocalAIClient(
            baseUrl: settings.baseUrl,
            apiKey: settings.apiKey,
            sessionToken: settings.sessionToken);

  Future<void> init() async {
    await refreshConversations();
    await checkConnection();
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) => checkConnection());
  }

  /// Connects to LocalAI only if it is started, then checks credentials
  /// against the server's auth policy.
  Future<void> checkConnection() async {
    client
      ..baseUrl = settings.baseUrl
      ..apiKey = settings.apiKey
      ..sessionToken = settings.sessionToken;
    var next = await client.probe();
    if (next == ServerState.ready) {
      auth = await client.authStatus();
      try {
        if (models.isEmpty || state != ServerState.ready) {
          models = await client.listModels();
          if (settings.chatModel.isEmpty && models.isNotEmpty) {
            settings.chatModel = models.first;
            await settings.save();
          }
        } else {
          // Cheap authenticated call to detect expired sessions/revoked keys.
          await client.listModels();
        }
      } on LocalAIException catch (e) {
        if (e.unauthorized) {
          next = ServerState.unauthenticated;
          models = [];
        }
      } catch (_) {}
    }
    state = next;
    notifyListeners();
  }

  Future<void> loginWithPassword(String email, String password) async {
    final token = await client.login(email, password);
    settings
      ..sessionToken = token
      ..userEmail = email;
    await settings.save();
    models = [];
    await checkConnection();
  }

  Future<void> loginWithApiKey(String key) async {
    settings
      ..apiKey = key
      ..sessionToken = '';
    await settings.save();
    models = [];
    await checkConnection();
  }

  Future<void> logout() async {
    await client.logout();
    settings
      ..sessionToken = ''
      ..userEmail = '';
    await settings.save();
    models = [];
    await checkConnection();
  }

  String offlineMessage() => switch (state) {
        ServerState.unauthenticated => 'Connexion à LocalAI requise.',
        ServerState.starting => 'LocalAI démarre (modèles en chargement)…',
        _ => 'LocalAI n\'est pas démarré (${settings.baseUrl}).',
      };

  void _handleError(Object e) {
    error = e.toString();
    if (e is LocalAIException && e.unauthorized) {
      state = ServerState.unauthenticated;
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

  /// Sends a user message and streams the reply. [extraSystem] is appended to
  /// the system prompt (Style oral); [onToken] sees each streamed piece.
  /// Returns the saved reply, or null if nothing came back.
  Future<ChatMessage?> send(String text, List<Attachment> attachments,
      {String extraSystem = '', void Function(String)? onToken}) async {
    if (busy || (text.trim().isEmpty && attachments.isEmpty)) return null;
    if (!online) {
      error = offlineMessage();
      notifyListeners();
      return null;
    }
    error = null;
    await _ensureConversation(text);
    await _add(ChatMessage(id: _uuid.v4(), role: 'user', content: text, attachments: attachments));
    return _complete(extraSystem: extraSystem, onToken: onToken);
  }

  /// Regenerates the last assistant answer.
  Future<void> regenerate() async {
    if (busy || messages.isEmpty) return;
    if (messages.last.role == 'assistant') messages.removeLast();
    await _complete();
  }

  Future<ChatMessage?> _complete({String extraSystem = '', void Function(String)? onToken}) async {
    final conv = current!;
    final history = messages.where((m) => m.role != 'system').toList();
    final reply = ChatMessage(id: _uuid.v4(), role: 'assistant', content: '');
    messages.add(reply);
    busy = true;
    notifyListeners();
    final done = _done = Completer<void>();
    _sub = client
        .chatStream(
          model: settings.chatModel,
          messages: history,
          systemPrompt: [settings.systemPrompt, extraSystem].where((s) => s.isNotEmpty).join('\n\n'),
          temperature: settings.temperature,
        )
        .listen((t) {
      reply.content += t;
      onToken?.call(t);
      notifyListeners();
    }, onError: (Object e) {
      _handleError(e);
      if (!done.isCompleted) done.complete();
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, cancelOnError: true);
    await done.future;
    await _finish(conv, reply);
    return reply.content.isEmpty ? null : reply;
  }

  Future<void> _finish(Conversation conv, ChatMessage reply) async {
    _sub = null;
    _done = null;
    busy = false;
    if (reply.content.isEmpty) {
      messages.remove(reply);
    } else {
      conv.updatedAt = DateTime.now();
      await db.saveMessage(conv.id, reply);
      await db.saveConversation(conv);
    }
    await refreshConversations();
  }

  /// Cancels the reply being streamed; [_complete] then saves what arrived.
  void stop() {
    _sub?.cancel();
    if (_done?.isCompleted == false) _done!.complete();
  }

  /// Interruption in the Mode vocal: keeps only what was spoken of [reply],
  /// or drops it when nothing was.
  Future<void> trimReply(ChatMessage reply, String keep) async {
    if (keep.isEmpty) {
      messages.remove(reply);
      await db.deleteMessage(reply.id);
    } else {
      reply.content = keep;
      await db.updateMessageContent(reply.id, keep);
    }
    notifyListeners();
  }

  /// Generates an image from a prompt and stores it in the conversation.
  Future<void> generateImage(String prompt) async {
    if (busy || prompt.trim().isEmpty) return;
    if (!online) {
      error = offlineMessage();
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
      _handleError(e);
    }
    busy = false;
    await refreshConversations();
  }

  Future<String> transcribe(Uint8List audio, String filename) =>
      client.transcribe(audio, filename, model: settings.sttModel, language: settings.sttLanguage);

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
