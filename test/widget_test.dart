import 'package:chatit/models.dart';
import 'package:chatit/services/localai_client.dart';
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

  test('extracts LocalAI session cookie', () {
    expect(
        LocalAIClient.cookieValue(
            'session=abc123; Path=/; HttpOnly; SameSite=Lax', 'session'),
        'abc123');
    expect(LocalAIClient.cookieValue('token=x; Path=/,session=s1; Path=/', 'session'), 's1');
    expect(LocalAIClient.cookieValue(null, 'session'), isNull);
  });

  test('parses /api/auth/status', () {
    final a = AuthStatus.fromJson({
      'authEnabled': true,
      'staticApiKeyRequired': false,
      'providers': ['local', 'github'],
      'user': null,
    });
    expect(a.open, isFalse);
    expect(a.passwordLogin, isTrue);
    expect(AuthStatus.fromJson({'authEnabled': false, 'staticApiKeyRequired': false}).open, isTrue);
  });
}
