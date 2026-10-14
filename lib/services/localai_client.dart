import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Client for LocalAI (https://github.com/mudler/LocalAI), which exposes an
/// OpenAI-compatible REST API.
/// Server state as seen by ChatIt, following LocalAI's connection policy:
/// `/readyz` and `/api/auth/status` are public, everything under `/v1` needs
/// credentials as soon as auth (users DB) or static API keys are enabled.
enum ServerState { offline, starting, unauthenticated, ready }

class AuthStatus {
  /// Multi-user auth (DB) enabled: user API keys or email/password sessions.
  final bool authEnabled;

  /// Legacy mode: server started with `--api-keys` / `LOCALAI_API_KEY`.
  final bool staticApiKeyRequired;
  final List<String> providers;
  final Map<String, dynamic>? user;

  AuthStatus({
    required this.authEnabled,
    required this.staticApiKeyRequired,
    required this.providers,
    this.user,
  });

  bool get open => !authEnabled && !staticApiKeyRequired;
  bool get passwordLogin => providers.contains('local');

  factory AuthStatus.fromJson(Map<String, dynamic> j) => AuthStatus(
        authEnabled: j['authEnabled'] == true,
        staticApiKeyRequired: j['staticApiKeyRequired'] == true,
        providers: ((j['providers'] as List?) ?? []).cast<String>(),
        user: j['user'] as Map<String, dynamic>?,
      );

  static final none =
      AuthStatus(authEnabled: false, staticApiKeyRequired: false, providers: const []);
}

class LocalAIClient {
  String baseUrl;

  /// Static API key or user API key (sent as `Authorization: Bearer`).
  String? apiKey;

  /// Session id obtained via `/api/auth/login`; LocalAI also accepts it as a
  /// Bearer token, which avoids cookie/CSRF handling on native clients.
  String? sessionToken;

  LocalAIClient({required this.baseUrl, this.apiKey, this.sessionToken});

  String? get _bearer => (sessionToken?.isNotEmpty ?? false)
      ? sessionToken
      : ((apiKey?.isNotEmpty ?? false) ? apiKey : null);

  Uri _u(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_bearer != null) 'Authorization': 'Bearer $_bearer',
      };

  /// Liveness/readiness probe, public on LocalAI (no credentials needed).
  Future<ServerState> probe() async {
    try {
      final r = await http.get(_u('/readyz')).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) return ServerState.ready;
      if (r.statusCode == 503) return ServerState.starting;
    } catch (_) {
      return ServerState.offline;
    }
    // Older LocalAI without /readyz.
    try {
      final r = await http.get(_u('/healthz')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200 ? ServerState.ready : ServerState.offline;
    } catch (_) {
      return ServerState.offline;
    }
  }

  /// Public endpoint describing which auth mode the server runs in. Returns
  /// [AuthStatus.none] on servers that predate it.
  Future<AuthStatus> authStatus() async {
    try {
      final r = await http
          .get(_u('/api/auth/status'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return AuthStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      }
    } catch (_) {}
    return AuthStatus.none;
  }

  /// Email/password login. Returns the session id to reuse as Bearer token.
  Future<String> login(String email, String password) async {
    final r = await http.post(_u('/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}));
    _check(r.statusCode, r.body, r.headers);
    final token = cookieValue(r.headers['set-cookie'], 'session');
    if (token == null) throw LocalAIException('Session absente de la réponse', 0);
    sessionToken = token;
    return token;
  }

  Future<void> logout() async {
    try {
      await http.post(_u('/api/auth/logout'), headers: {
        ..._headers,
        if (sessionToken != null) 'Cookie': 'session=$sessionToken',
      });
    } catch (_) {}
    sessionToken = null;
  }

  static String? cookieValue(String? header, String name) {
    if (header == null) return null;
    final m = RegExp('(?:^|[,;]\\s*)$name=([^;,]+)').firstMatch(header);
    return m?.group(1);
  }

  Future<List<String>> listModels() async {
    final r = await http.get(_u('/v1/models'), headers: _headers);
    _check(r.statusCode, r.body, r.headers);
    final data = jsonDecode(r.body)['data'] as List;
    return data.map((m) => m['id'] as String).toList()..sort();
  }

  /// Streams assistant tokens from /v1/chat/completions.
  Stream<String> chatStream({
    required String model,
    required List<ChatMessage> messages,
    String? systemPrompt,
    double temperature = 0.7,
  }) async* {
    final payload = {
      'model': model,
      'stream': true,
      'temperature': temperature,
      'messages': [
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        ...messages.map(_toApi),
      ],
    };
    final req = http.Request('POST', _u('/v1/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(payload);
    final client = http.Client();
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) {
        _check(res.statusCode, await res.stream.bytesToString(), res.headers);
      }
      var buffer = '';
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();
        for (final line in lines) {
          final l = line.trim();
          if (!l.startsWith('data:')) continue;
          final d = l.substring(5).trim();
          if (d == '[DONE]') return;
          try {
            final delta = jsonDecode(d)['choices'][0]['delta'];
            final c = delta?['content'];
            if (c is String && c.isNotEmpty) yield c;
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> _toApi(ChatMessage m) {
    final images = m.attachments.where((a) => a.kind == AttachmentKind.image);
    final docs = m.attachments.where((a) => a.kind == AttachmentKind.document);
    var text = m.content;
    for (final d in docs) {
      text += '\n\n--- Document: ${d.name} ---\n${d.data}';
    }
    if (images.isEmpty) return {'role': m.role, 'content': text};
    return {
      'role': m.role,
      'content': [
        {'type': 'text', 'text': text},
        ...images.map((i) => {
              'type': 'image_url',
              'image_url': {'url': 'data:${i.mime ?? 'image/png'};base64,${i.data}'},
            }),
      ],
    };
  }

  /// Image generation (Stable Diffusion / Flux backends). Returns base64 PNGs.
  Future<List<String>> generateImage(String prompt,
      {String? model, String size = '512x512'}) async {
    final r = await http.post(_u('/v1/images/generations'),
        headers: _headers,
        body: jsonEncode({
          'prompt': prompt,
          'size': size,
          'response_format': 'b64_json',
          if (model != null && model.isNotEmpty) 'model': model,
        }));
    _check(r.statusCode, r.body, r.headers);
    final out = <String>[];
    for (final d in (jsonDecode(r.body)['data'] as List)) {
      if (d['b64_json'] != null) {
        out.add(d['b64_json'] as String);
      } else if (d['url'] != null) {
        final img = await http.get(Uri.parse(d['url'] as String));
        out.add(base64Encode(img.bodyBytes));
      }
    }
    return out;
  }

  /// Speech to text (whisper backend).
  /// [language] (ISO 639-1, e.g. `fr`) avoids whisper misdetecting short
  /// utterances; empty or `auto` lets whisper detect it.
  Future<String> transcribe(Uint8List audio, String filename,
      {String model = 'whisper-1', String language = ''}) async {
    final req = http.MultipartRequest('POST', _u('/v1/audio/transcriptions'))
      ..headers.addAll({..._headers}..remove('Content-Type'))
      ..fields['model'] = model
      ..files.add(http.MultipartFile.fromBytes('file', audio, filename: filename));
    if (language.isNotEmpty && language != 'auto') req.fields['language'] = language;
    final res = await http.Response.fromStream(await req.send());
    _check(res.statusCode, res.body, res.headers);
    return (jsonDecode(res.body)['text'] as String? ?? '').trim();
  }

  /// Text to speech (piper / bark / coqui backends). Returns audio bytes.
  Future<Uint8List> speak(String text, {String model = 'tts-1', String? voice}) async {
    final r = await http.post(_u('/v1/audio/speech'),
        headers: _headers,
        body: jsonEncode({
          'model': model,
          'input': text,
          if (voice != null && voice.isNotEmpty) 'voice': voice,
        }));
    _check(r.statusCode, r.body, r.headers);
    return r.bodyBytes;
  }

  void _check(int code, String body, [Map<String, String>? headers]) {
    if (code >= 200 && code < 300) return;
    String msg = body;
    try {
      final j = jsonDecode(body);
      msg = (j['error'] is Map ? j['error']['message'] : j['error'])?.toString() ?? body;
    } catch (_) {}
    switch (code) {
      case 401:
        throw LocalAIException('Authentification requise ou identifiants invalides', code);
      case 403:
        throw LocalAIException('Accès refusé : $msg', code);
      case 429:
        final retry = headers?['retry-after'];
        throw LocalAIException(
            'Quota atteint : $msg${retry != null ? ' (réessayer dans ${retry}s)' : ''}', code);
      default:
        throw LocalAIException('HTTP $code : $msg', code);
    }
  }
}

class LocalAIException implements Exception {
  final String message;
  final int statusCode;
  LocalAIException(this.message, this.statusCode);
  bool get unauthorized => statusCode == 401;
  @override
  String toString() => message;
}
