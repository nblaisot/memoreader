import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epubx/epubx.dart';

import '../utils/html_text_extractor.dart';
import 'epub_content_resolver.dart';

/// The single text/offset coordinate system shared by reader-facing RAG paths.
class CanonicalBookText {
  const CanonicalBookText({
    required this.text,
    required this.sections,
    required this.contentHash,
    required this.extractionVersion,
  });

  final String text;
  final List<CanonicalBookSection> sections;
  final String contentHash;
  final int extractionVersion;
}

class CanonicalBookSection {
  const CanonicalBookSection({
    required this.sectionIndex,
    required this.chapterIndex,
    required this.contentFileKey,
    required this.charStart,
    required this.charEnd,
    required this.text,
    this.chapterTitle,
  });

  final int sectionIndex;
  final int chapterIndex;
  final String contentFileKey;
  final String? chapterTitle;
  final int charStart;
  final int charEnd;
  final String text;
}

class CanonicalBookTextService {
  const CanonicalBookTextService();

  static const int extractionVersion = 1;

  Future<CanonicalBookText> fromFile(File epubFile) async {
    final bytes = await epubFile.readAsBytes();
    return fromEpub(await EpubReader.readBook(bytes));
  }

  CanonicalBookText fromEpub(EpubBook epub) {
    final resolution = EpubContentResolver.resolve(epub);
    final buffer = StringBuffer();
    final sections = <CanonicalBookSection>[];

    for (final source in resolution.sections) {
      final text = HtmlTextExtractor.extract(source.html);
      if (text.isEmpty) continue;
      final start = buffer.length;
      buffer.write(text);
      sections.add(
        CanonicalBookSection(
          sectionIndex: source.sectionIndex,
          chapterIndex: source.chapterIndex,
          contentFileKey: source.contentFileKey,
          chapterTitle: source.chapterTitle,
          charStart: start,
          charEnd: buffer.length,
          text: text,
        ),
      );
    }

    final text = buffer.toString();
    return CanonicalBookText(
      text: text,
      sections: List.unmodifiable(sections),
      contentHash: sha256.convert(utf8.encode(text)).toString(),
      extractionVersion: extractionVersion,
    );
  }
}
