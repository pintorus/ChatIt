import 'package:chatit/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('attachments round-trip through JSON', () {
    final m = ChatMessage(id: '1', role: 'user', content: 'hi', attachments: [
      Attachment(kind: AttachmentKind.document, name: 'a.txt', data: 'hello'),
    ]);
    final back = ChatMessage.attachmentsFromJson(m.attachmentsJson);
    expect(back.single.name, 'a.txt');
    expect(back.single.kind, AttachmentKind.document);
  });
}
