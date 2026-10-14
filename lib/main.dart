import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import 'data/history_db.dart';
import 'state/chat_controller.dart';
import 'state/settings.dart';
import 'ui/chat_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Mode vocal notification buttons are relayed from the service isolate.
  FlutterForegroundTask.initCommunicationPort();
  final settings = Settings();
  await settings.load();
  final db = HistoryDb();
  await db.open();
  final chat = ChatController(db, settings);
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: chat),
    ],
    child: const ChatItApp(),
  ));
  chat.init();
}

class ChatItApp extends StatelessWidget {
  const ChatItApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = context.watch<Settings>().darkMode;
    const seed = Color(0xFF1565C0);
    return MaterialApp(
      title: 'Chat It',
      debugShowCheckedModeBanner: false,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const ChatPage(),
    );
  }
}
