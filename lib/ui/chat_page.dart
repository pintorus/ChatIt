import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../models.dart';
import '../services/document_reader.dart';
import '../services/localai_client.dart';
import '../state/chat_controller.dart';
import '../state/settings.dart';
import 'login_dialog.dart';
import 'settings_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final List<Attachment> _pending = [];
  bool _imageMode = false;
  bool _recording = false;
  bool _transcribing = false;
  int _lastCount = 0;

  ChatController get _c => context.read<ChatController>();

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _send() async {
    final text = _input.text;
    final atts = List<Attachment>.from(_pending);
    _input.clear();
    setState(() => _pending.clear());
    if (_imageMode) {
      await _c.generateImage(text);
    } else {
      await _c.send(text, atts);
      if (!mounted) return;
      final s = context.read<Settings>();
      if (s.autoSpeak && _c.messages.isNotEmpty && _c.messages.last.role == 'assistant') {
        await _speak(_c.messages.last.content);
      }
    }
  }

  Future<void> _pickImage(ImageSource src) async {
    final f = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 85);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    final ext = p.extension(f.name).replaceFirst('.', '').toLowerCase();
    setState(() => _pending.add(Attachment(
        kind: AttachmentKind.image,
        name: f.name,
        mime: 'image/${ext == 'jpg' ? 'jpeg' : (ext.isEmpty ? 'png' : ext)}',
        data: base64Encode(bytes))));
  }

  Future<void> _pickDocument() async {
    final r = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: DocumentReader.supported);
    if (r.isEmpty) return;
    final f = r.single;
    try {
      final text = DocumentReader.extract(f.name, await f.xFile.readAsBytes());
      setState(() => _pending.add(
          Attachment(kind: AttachmentKind.document, name: f.name, data: text)));
    } catch (e) {
      _toast('Lecture impossible : $e');
    }
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      final path = await _recorder.stop();
      setState(() {
        _recording = false;
        _transcribing = true;
      });
      try {
        if (path != null) {
          final bytes = kIsWeb
              ? (await NetworkAssetBundle(Uri.parse(path)).load(path)).buffer.asUint8List()
              : await File(path).readAsBytes();
          final text = await _c.transcribe(bytes, 'audio.wav');
          _input.text = [_input.text, text].where((s) => s.isNotEmpty).join(' ');
        }
      } catch (e) {
        _toast('Transcription : $e');
      }
      setState(() => _transcribing = false);
      return;
    }
    if (!await _recorder.hasPermission()) {
      _toast('Permission micro refusée');
      return;
    }
    final path = kIsWeb
        ? ''
        : p.join((await getTemporaryDirectory()).path, 'chatit_rec.wav');
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
        path: path);
    setState(() => _recording = true);
  }

  Future<void> _speak(String text) async {
    try {
      final audio = await _c.speak(text);
      await _player.play(BytesSource(audio));
    } catch (e) {
      _toast('Synthèse vocale : $e');
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();
    if (c.messages.length != _lastCount || c.busy) {
      _lastCount = c.messages.length;
      _scrollToEnd();
    }
    final wide = MediaQuery.sizeOf(context).width > 900;
    final drawer = _HistoryDrawer(onSelected: () {
      if (!wide) Navigator.of(context).maybePop();
    });
    return Scaffold(
      drawer: wide ? null : Drawer(child: drawer),
      appBar: AppBar(
        title: Text(c.current?.title ?? 'ChatIt', overflow: TextOverflow.ellipsis),
        actions: [
          _StatusChip(state: c.state, onTap: c.checkConnection),
          IconButton(
              tooltip: 'Nouvelle conversation',
              icon: const Icon(Icons.edit_square),
              onPressed: c.newConversation),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'settings') {
                await Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const SettingsPage()));
              } else if (v == 'export') {
                await Clipboard.setData(ClipboardData(text: c.exportCurrent()));
                _toast('Conversation copiée (JSON)');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Exporter la conversation')),
              PopupMenuItem(value: 'settings', child: Text('Paramètres')),
            ],
          ),
        ],
      ),
      body: Row(children: [
        if (wide) SizedBox(width: 300, child: Material(elevation: 1, child: drawer)),
        Expanded(
          child: Column(children: [
            if (c.state == ServerState.unauthenticated)
              MaterialBanner(
                content: Text(c.auth.staticApiKeyRequired
                    ? 'LocalAI demande une clé API.'
                    : 'LocalAI demande une connexion (session expirée ou clé invalide).'),
                leading: const Icon(Icons.lock),
                actions: [
                  TextButton(
                      onPressed: () => showLoginDialog(context), child: const Text('Se connecter')),
                ],
              )
            else if (!c.online)
              MaterialBanner(
                content: Text(c.state == ServerState.starting
                    ? 'LocalAI démarre…'
                    : 'LocalAI n\'est pas démarré sur ${context.read<Settings>().baseUrl}'),
                leading: const Icon(Icons.cloud_off),
                actions: [TextButton(onPressed: c.checkConnection, child: const Text('Réessayer'))],
              ),
            Expanded(
              child: c.messages.isEmpty
                  ? const _Welcome()
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: c.messages.length,
                      itemBuilder: (_, i) => _Bubble(
                        message: c.messages[i],
                        streaming: c.busy && i == c.messages.length - 1,
                        onSpeak: _speak,
                        onRegenerate: i == c.messages.length - 1 && !c.busy
                            ? c.regenerate
                            : null,
                      ),
                    ),
            ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            _composer(c),
          ]),
        ),
      ]),
    );
  }

  Widget _composer(ChatController c) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_pending.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final a in _pending)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: InputChip(
                      avatar: a.kind == AttachmentKind.image
                          ? CircleAvatar(backgroundImage: MemoryImage(base64Decode(a.data)))
                          : const Icon(Icons.description),
                      label: Text(a.name),
                      onDeleted: () => setState(() => _pending.remove(a)),
                    ),
                  ),
              ]),
            ),
          Container(
            decoration: BoxDecoration(
                color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(28)),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Joindre',
                onSelected: (v) {
                  switch (v) {
                    case 'gallery':
                      _pickImage(ImageSource.gallery);
                    case 'camera':
                      _pickImage(ImageSource.camera);
                    case 'doc':
                      _pickDocument();
                    case 'imagine':
                      setState(() => _imageMode = !_imageMode);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'gallery', child: ListTile(leading: Icon(Icons.photo), title: Text('Image'))),
                  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
                    const PopupMenuItem(value: 'camera', child: ListTile(leading: Icon(Icons.photo_camera), title: Text('Appareil photo'))),
                  const PopupMenuItem(value: 'doc', child: ListTile(leading: Icon(Icons.attach_file), title: Text('Document'))),
                  PopupMenuItem(
                      value: 'imagine',
                      child: ListTile(
                          leading: const Icon(Icons.brush),
                          title: Text(_imageMode ? 'Mode texte' : 'Créer une image'))),
                ],
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _transcribing
                        ? 'Transcription…'
                        : _imageMode
                            ? 'Décrivez l\'image à créer'
                            : 'Message ChatIt',
                    prefixIcon: _imageMode ? const Icon(Icons.brush, size: 18) : null,
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Dicter',
                icon: Icon(_recording ? Icons.stop_circle : Icons.mic,
                    color: _recording ? cs.error : null),
                onPressed: _transcribing ? null : _toggleRecord,
              ),
              c.busy
                  ? IconButton(icon: const Icon(Icons.stop), onPressed: c.stop)
                  : IconButton.filled(icon: const Icon(Icons.arrow_upward), onPressed: _send),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final ServerState state;
  final VoidCallback onTap;
  const _StatusChip({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      ServerState.ready => ('LocalAI connecté', Colors.green),
      ServerState.unauthenticated => ('Connexion requise', Colors.orange),
      ServerState.starting => ('LocalAI démarre', Colors.amber),
      ServerState.offline => ('LocalAI hors ligne', Colors.red),
    };
    return Tooltip(
      message: label,
      child: IconButton(
        onPressed: state == ServerState.unauthenticated ? () => showLoginDialog(context) : onTap,
        icon: Icon(Icons.circle, size: 12, color: color),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('assets/icon/chatit.png', width: 96, height: 96),
          const SizedBox(height: 16),
          Text('Comment puis-je vous aider ?', style: Theme.of(context).textTheme.headlineSmall),
        ]),
      );
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool streaming;
  final Future<void> Function(String) onSpeak;
  final VoidCallback? onRegenerate;

  const _Bubble(
      {required this.message, required this.streaming, required this.onSpeak, this.onRegenerate});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = message.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: user ? cs.primaryContainer : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final a in message.attachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: a.kind == AttachmentKind.image
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(base64Decode(a.data), width: 320, fit: BoxFit.cover))
                    : Chip(avatar: const Icon(Icons.description, size: 18), label: Text(a.name)),
              ),
            if (message.content.isEmpty && streaming)
              const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            else
              MarkdownBody(data: message.content, selectable: true),
            if (!user && !streaming && message.content.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    iconSize: 18,
                    tooltip: 'Copier',
                    icon: const Icon(Icons.copy),
                    onPressed: () => Clipboard.setData(ClipboardData(text: message.content))),
                IconButton(
                    iconSize: 18,
                    tooltip: 'Lire',
                    icon: const Icon(Icons.volume_up),
                    onPressed: () => onSpeak(message.content)),
                if (onRegenerate != null)
                  IconButton(
                      iconSize: 18,
                      tooltip: 'Régénérer',
                      icon: const Icon(Icons.refresh),
                      onPressed: onRegenerate),
              ]),
          ]),
        ),
      ),
    );
  }
}

class _HistoryDrawer extends StatelessWidget {
  final VoidCallback onSelected;
  const _HistoryDrawer({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'Rechercher', border: OutlineInputBorder()),
            onChanged: c.refreshConversations,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Nouvelle conversation'),
          onTap: () {
            c.newConversation();
            onSelected();
          },
        ),
        const Divider(),
        Expanded(
          child: ListView(children: [
            for (final conv in c.conversations)
              ListTile(
                selected: conv.id == c.current?.id,
                title: Text(conv.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  c.open(conv);
                  onSelected();
                },
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'delete') {
                      await c.delete(conv);
                    } else {
                      final ctrl = TextEditingController(text: conv.title);
                      final t = await showDialog<String>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: const Text('Renommer'),
                          content: TextField(controller: ctrl, autofocus: true),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Annuler')),
                            FilledButton(
                                onPressed: () => Navigator.pop(d, ctrl.text),
                                child: const Text('OK')),
                          ],
                        ),
                      );
                      if (t != null && t.trim().isNotEmpty) await c.rename(conv, t.trim());
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Renommer')),
                    PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                  ],
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}
