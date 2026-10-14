import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/chat_controller.dart';
import '../state/settings.dart';
import '../state/voice_controller.dart';

/// Mode vocal: full-screen voice conversation around the Orbe.
class VoicePage extends StatefulWidget {
  const VoicePage({super.key});

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> with SingleTickerProviderStateMixin {
  late final VoiceController v =
      VoiceController(context.read<ChatController>(), context.read<Settings>());
  late final _breath =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
        ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    v.addListener(_onChange);
    v.start();
  }

  /// "Quitter" from the notification closes the page too.
  void _onChange() {
    if (v.closed && mounted) {
      v.removeListener(_onChange);
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    v.removeListener(_onChange);
    v.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([v, _breath]),
          builder: (context, _) {
            final color = v.muted
                ? Colors.grey
                : switch (v.phase) {
                    VoicePhase.listening => Colors.lightBlueAccent,
                    VoicePhase.thinking => Colors.purpleAccent,
                    VoicePhase.speaking => Colors.white,
                    VoicePhase.error => Colors.redAccent,
                  };
            final scale = 1 +
                0.35 * v.level +
                (v.phase == VoicePhase.thinking && !v.muted ? 0.06 * _breath.value : 0);
            return Column(children: [
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(v.statusText,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    style: TextStyle(
                        color: v.phase == VoicePhase.error ? Colors.redAccent : Colors.white70,
                        fontSize: 16)),
              ),
              Expanded(
                child: Center(
                  child: Semantics(
                    label: 'Orbe : ${v.statusText}',
                    child: AnimatedScale(
                      scale: scale,
                      duration: const Duration(milliseconds: 90),
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                              colors: [color, color.withValues(alpha: 0.35)]),
                          boxShadow: [
                            BoxShadow(
                                color: color.withValues(alpha: 0.5),
                                blurRadius: 40 + 40 * v.level),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: v.heard == null ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  child: Text(v.heard ?? '',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54)),
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: v.muted ? 'Réactiver le micro' : 'Couper le micro',
                  icon: Icon(v.muted ? Icons.mic_off : Icons.mic),
                  onPressed: v.toggleMute,
                ),
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: 'Quitter le mode vocal',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ]),
              const SizedBox(height: 32),
            ]);
          },
        ),
      ),
    );
  }
}
