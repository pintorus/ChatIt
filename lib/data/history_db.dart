import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi;

import '../models.dart';

/// Local conversation history (SQLite).
class HistoryDb {
  late Database _db;

  Future<void> open() async {
    if ((Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'chatit.db'),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE conversations(
          id TEXT PRIMARY KEY, title TEXT, model TEXT,
          created_at INTEGER, updated_at INTEGER)''');
        await db.execute('''CREATE TABLE messages(
          id TEXT PRIMARY KEY,
          conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
          role TEXT, content TEXT, attachments TEXT, created_at INTEGER)''');
      },
    );
  }

  Future<List<Conversation>> conversations({String? search}) async {
    final rows = search == null || search.isEmpty
        ? await _db.query('conversations', orderBy: 'updated_at DESC')
        : await _db.rawQuery('''SELECT DISTINCT c.* FROM conversations c
            LEFT JOIN messages m ON m.conversation_id = c.id
            WHERE c.title LIKE ? OR m.content LIKE ?
            ORDER BY c.updated_at DESC''', ['%$search%', '%$search%']);
    return rows
        .map((r) => Conversation(
              id: r['id'] as String,
              title: r['title'] as String,
              model: r['model'] as String?,
              createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
              updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
            ))
        .toList();
  }

  Future<List<ChatMessage>> messages(String conversationId) async {
    final rows = await _db.query('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId], orderBy: 'created_at');
    return rows
        .map((r) => ChatMessage(
              id: r['id'] as String,
              role: r['role'] as String,
              content: r['content'] as String,
              attachments: ChatMessage.attachmentsFromJson(r['attachments'] as String?),
              createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
            ))
        .toList();
  }

  Future<void> saveConversation(Conversation c) => _db.insert(
      'conversations',
      {
        'id': c.id,
        'title': c.title,
        'model': c.model,
        'created_at': c.createdAt.millisecondsSinceEpoch,
        'updated_at': c.updatedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> saveMessage(String conversationId, ChatMessage m) => _db.insert(
      'messages',
      {
        'id': m.id,
        'conversation_id': conversationId,
        'role': m.role,
        'content': m.content,
        'attachments': m.attachmentsJson,
        'created_at': m.createdAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteMessage(String id) => _db.delete('messages', where: 'id = ?', whereArgs: [id]);

  Future<void> updateMessageContent(String id, String content) =>
      _db.update('messages', {'content': content}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteConversation(String id) =>
      _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
}
