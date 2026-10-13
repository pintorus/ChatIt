import 'dart:convert';
import 'dart:typed_data';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Extracts plain text from documents so it can be injected in the prompt.
class DocumentReader {
  static const textExtensions = [
    'txt', 'md', 'csv', 'json', 'xml', 'html', 'yaml', 'yml', 'log',
    'dart', 'java', 'kt', 'py', 'js', 'ts', 'c', 'cpp', 'h', 'sql', 'sh',
  ];
  static const supported = ['pdf', ...textExtensions];

  static const maxChars = 60000;

  static String extract(String name, Uint8List bytes) {
    final ext = name.split('.').last.toLowerCase();
    String text;
    if (ext == 'pdf') {
      final doc = PdfDocument(inputBytes: bytes);
      text = PdfTextExtractor(doc).extractText();
      doc.dispose();
    } else {
      text = utf8.decode(bytes, allowMalformed: true);
    }
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars)}\n[… document tronqué …]';
    }
    return text;
  }
}
