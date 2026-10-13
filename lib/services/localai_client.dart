import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Client for LocalAI (https://github.com/mudler/LocalAI), which exposes an
/// OpenAI-compatible REST API.
class LocalAIClient {
  String baseUrl;
  String? apiKey;

  LocalAIClient({required this.baseUrl, this.apiKey});

  Uri _u(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

  /// Returns true when LocalAI is started and answering.
  Future<bool> ping() async {
    try {
      final r = await http
          .get(_u('/readyz'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) return true;
    } catch (_) {}
    try {
      final r = await http
          .get(_u('/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> listModels() async {
    final r = await http.get(_u('/v1/models'), headers: _headers);
    _check(r.statusCode, r.body);
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
        _check(res.statusCode, await res.stream.bytesToString());
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
    _check(r.statusCode, r.body);
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
  Future<String> transcribe(Uint8List audio, String filename, {String model = 'whisper-1'}) async {
    final req = http.MultipartRequest('POST', _u('/v1/audio/transcriptions'))
      ..headers.addAll({..._headers}..remove('Content-Type'))
      ..fields['model'] = model
      ..files.add(http.MultipartFile.fromBytes('file', audio, filename: filename));
    final res = await http.Response.fromStream(await req.send());
    _check(res.statusCode, res.body);
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
    _check(r.statusCode, r.body);
    return r.bodyBytes;
  }

  void _check(int code, String body) {
    if (code < 200 || code >= 300) {
      throw LocalAIException('HTTP $code: $body');
    }
  }
}

class LocalAIException implements Exception {
  final String message;
  LocalAIException(this.message);
  @override
  String toString() => message;
}
