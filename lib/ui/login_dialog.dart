import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/chat_controller.dart';

/// Sign-in adapted to the server's auth mode (from `/api/auth/status`):
/// static API key, user API key, or email/password session.
Future<void> showLoginDialog(BuildContext context) => showDialog(
      context: context,
      builder: (_) => const _LoginDialog(),
    );

class _LoginDialog extends StatefulWidget {
  const _LoginDialog();

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  late bool _useKey;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final auth = context.read<ChatController>().auth;
    _useKey = !auth.authEnabled || !auth.passwordLogin;
  }

  Future<void> _submit() async {
    final c = context.read<ChatController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_useKey) {
        await c.loginWithApiKey(_key.text.trim());
      } else {
        await c.loginWithPassword(_email.text.trim(), _password.text);
      }
      if (!c.online) throw Exception('Identifiants refusés par LocalAI');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<ChatController>().auth;
    final canPassword = auth.authEnabled && auth.passwordLogin;
    final oauthOnly = auth.authEnabled && !auth.passwordLogin && auth.providers.isNotEmpty;
    return AlertDialog(
      title: const Text('Connexion à LocalAI'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (canPassword)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Compte')),
                ButtonSegment(value: true, label: Text('Clé API')),
              ],
              selected: {_useKey},
              onSelectionChanged: (v) => setState(() => _useKey = v.first),
            ),
          if (oauthOnly)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Ce serveur utilise une connexion OAuth/OIDC : créez une clé API '
                  'depuis l\'interface web de LocalAI puis collez-la ici.'),
            ),
          const SizedBox(height: 12),
          if (_useKey)
            TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                labelText: auth.staticApiKeyRequired ? 'Clé API du serveur' : 'Clé API utilisateur',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            )
          else ...[
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Mot de passe', border: OutlineInputBorder()),
              onSubmitted: (_) => _submit(),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Se connecter'),
        ),
      ],
    );
  }
}
