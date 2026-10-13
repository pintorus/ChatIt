import 'dart:convert';

enum AttachmentKind { image, document, audio }

class Attachment {
  final AttachmentKind kind;
  final String name;
  final String? mime;

  /// Base64 data for images/audio, extracted text for documents.
  final String data;

  Attachment({required this.kind, required this.name, required this.data, this.mime});

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'name': name, 'mime': mime, 'data': data};

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        kind: AttachmentKind.values.byName(j['kind'] as String),
        name: j['name'] as String,
        mime: j['mime'] as String?,
        data: j['data'] as String,
      );
}

class ChatMessage {
  final String id;
  final String role; // user | assistant | system
  String content;
  final List<Attachment> attachments;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    List<Attachment>? attachments,
    DateTime? createdAt,
  })  : attachments = attachments ?? [],
        createdAt = createdAt ?? DateTime.now();

  String get attachmentsJson =>
      jsonEncode(attachments.map((a) => a.toJson()).toList());

  static List<Attachment> attachmentsFromJson(String? s) => s == null || s.isEmpty
      ? []
      : (jsonDecode(s) as List)
          .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
          .toList();
}

class Conversation {
  final String id;
  String title;
  String? model;
  final DateTime createdAt;
  DateTime updatedAt;

  Conversation({
    required this.id,
    required this.title,
    this.model,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}
