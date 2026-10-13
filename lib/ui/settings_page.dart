import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/chat_controller.dart';
import '../state/settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Settings s = context.read<Settings>();
  late final url = TextEditingController(text: s.baseUrl);
  late final key = TextEditingController(text: s.apiKey);
  late final img = TextEditingController(text: s.imageModel);
  late final stt = TextEditingController(text: s.sttModel);
  late final tts = TextEditingController(text: s.ttsModel);
  late final voice = TextEditingController(text: s.ttsVoice);
  late final sys = TextEditingController(text: s.systemPrompt);

  Future<void> _save() async {
    s
      ..baseUrl = url.text.trim()
      ..apiKey = key.text.trim()
      ..imageModel = img.text.trim()
      ..sttModel = stt.text.trim()
      ..ttsModel = tts.text.trim()
      ..ttsVoice = voice.text.trim()
      ..systemPrompt = sys.text;
    await s.save();
    if (!mounted) return;
    final c = context.read<ChatController>();
    c.models = [];
    await c.checkConnection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(c.online ? 'Connecté à LocalAI ✓' : 'LocalAI injoignable')));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();
    Widget field(TextEditingController t, String label, {int lines = 1, bool obscure = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: t,
            maxLines: lines,
            obscureText: obscure,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres'), actions: [
        IconButton(icon: const Icon(Icons.save), onPressed: _save),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Serveur LocalAI', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        field(url, 'URL (ex. http://192.168.1.10:8080)'),
        field(key, 'Clé API (optionnelle)', obscure: true),
        Text('Modèles', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: c.models.contains(s.chatModel) ? s.chatModel : null,
          items: c.models.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
          onChanged: (v) => s.chatModel = v ?? '',
          decoration: const InputDecoration(
              labelText: 'Modèle de chat', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        field(img, 'Modèle image (ex. stablediffusion)'),
        field(stt, 'Modèle transcription (ex. whisper-1)'),
        field(tts, 'Modèle synthèse vocale (ex. tts-1)'),
        field(voice, 'Voix TTS (optionnelle)'),
        field(sys, 'Instructions système', lines: 4),
        Text('Température : ${s.temperature.toStringAsFixed(1)}'),
        StatefulBuilder(
          builder: (_, set) => Slider(
              value: s.temperature,
              max: 2,
              divisions: 20,
              onChanged: (v) => set(() => s.temperature = v)),
        ),
        StatefulBuilder(
          builder: (_, set) => Column(children: [
            SwitchListTile(
                title: const Text('Lire les réponses à voix haute'),
                value: s.autoSpeak,
                onChanged: (v) => set(() => s.autoSpeak = v)),
            SwitchListTile(
                title: const Text('Thème sombre'),
                value: s.darkMode,
                onChanged: (v) => set(() => s.darkMode = v)),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: _save, icon: const Icon(Icons.save), label: const Text('Enregistrer')),
      ]),
    );
  }
}
