import 'dart:io';

import 'package:flutter/services.dart';

/// PDF text/metadata via PDFKit on macOS (`MainFlutterWindow.swift` MethodChannel).
/// `flutter_pdf_text` does not implement macOS.
class PdfMacosText {
  PdfMacosText._();

  static const MethodChannel _channel =
      MethodChannel('com.memoreader.app/pdf_text');

  static Future<PdfMacosExtractResult> extract(File pdfFile) async {
    final dynamic raw = await _channel.invokeMethod<dynamic>(
      'extractText',
      pdfFile.path,
    );
    if (raw is! Map) {
      throw Exception('Unexpected PDF extract response');
    }
    final map = Map<String, dynamic>.from(raw);
    final text = map['text'] as String? ?? '';
    return PdfMacosExtractResult(
      text: text,
      title: map['title'] as String?,
      author: map['author'] as String?,
    );
  }
}

class PdfMacosExtractResult {
  const PdfMacosExtractResult({
    required this.text,
    this.title,
    this.author,
  });

  final String text;
  final String? title;
  final String? author;
}
