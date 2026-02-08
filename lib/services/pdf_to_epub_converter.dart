import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pdf_text/flutter_pdf_text.dart';

/// Service for converting PDF files to EPUB format
///
/// Extracts text from PDF (preserving paragraphs and line breaks, not page breaks),
/// then creates a minimal EPUB 3.0 structure like [TxtToEpubConverter].
class PdfToEpubConverter {
  static const String _defaultTitle = 'Unknown Title';
  static const String _defaultAuthor = 'Unknown Author';
  static const String _pageSeparator = '\n\n';
  static const String _mimetypeEpubZip = 'application/epub+zip';
  static const int _maxLinesForAuthorExtraction = 10;

  static final RegExp _authorByPattern = RegExp(r'^by\s+(.+)$', caseSensitive: false);
  static final RegExp _authorLabelPattern = RegExp(r'^author[:\s]+(.+)$', caseSensitive: false);
  static final RegExp _paragraphSplitPattern = RegExp(r'\n\n+');

  /// Convert a PDF file to EPUB format and save it to the specified path
  ///
  /// Returns metadata extracted from the file (title, author)
  /// Throws [Exception] if the PDF has no extractable text or encoding fails.
  Future<PdfToEpubMetadata> convertToEpub({
    required File pdfFile,
    required String outputEpubPath,
  }) async {
    try {
      final doc = await PDFDoc.fromFile(pdfFile);

      final textContent = await _extractTextFromPdf(doc);
      if (textContent.trim().isEmpty) {
        throw Exception('PDF contains no extractable text (may be image-only)');
      }

      final metadata = _extractMetadata(pdfFile.path, textContent, doc.info);
      final processedContent = _processPdfText(textContent);
      final archive = _createEpubArchive(metadata, processedContent);

      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) {
        throw Exception('Failed to encode EPUB archive');
      }

      final outputFile = File(outputEpubPath);
      await outputFile.writeAsBytes(zipBytes);

      debugPrint('PDF to EPUB conversion successful: $outputEpubPath');
      return metadata;
    } on Exception catch (e) {
      debugPrint('Error converting PDF to EPUB: $e');
      rethrow;
    }
  }

  /// Extract text from PDF preserving paragraph and line break structure.
  /// Concatenates all pages with double newline between pages (no page break markers).
  Future<String> _extractTextFromPdf(PDFDoc doc) async {
    final parts = <String>[];
    for (var i = 1; i <= doc.length; i++) {
      final page = doc.pageAt(i);
      final pageText = await page.text;
      if (pageText.trim().isNotEmpty) {
        parts.add(pageText);
      }
    }
    return parts.join(_pageSeparator);
  }

  /// Extract metadata from file path, text content, and PDF document info
  PdfToEpubMetadata _extractMetadata(
      String filePath, String textContent, PDFDocInfo? pdfInfo) {
    String? title = pdfInfo?.title?.trim();
    String? author = pdfInfo?.author?.trim();
    final authors = pdfInfo?.authors;
    if (authors != null && authors.isNotEmpty) {
      author ??= authors.join(', ');
    }

    final filenameWithoutExt = _filenameWithoutExtension(filePath);
    final titleFromFile = _titleCaseFromFilename(filenameWithoutExt);
    title ??= titleFromFile.isNotEmpty ? titleFromFile : _defaultTitle;
    author ??= _extractAuthorFromContent(textContent);
    author ??= _defaultAuthor;

    return PdfToEpubMetadata(title: title, author: author);
  }

  String _filenameWithoutExtension(String filePath) {
    final filename = filePath.replaceAll('\\', '/').split('/').last;
    final lastDot = filename.lastIndexOf('.');
    return lastDot > 0 ? filename.substring(0, lastDot) : filename;
  }

  String _titleCaseFromFilename(String filenameWithoutExt) {
    final normalized = filenameWithoutExt
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .trim();
    if (normalized.isEmpty) return '';
    return normalized
        .split(' ')
        .map((word) =>
            word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }

  /// Tries to find author in first lines (e.g. "By X" or "Author: X")
  String? _extractAuthorFromContent(String textContent) {
    final lines =
        textContent.split('\n').take(_maxLinesForAuthorExtraction).toList();
    for (final line in lines) {
      final trimmed = line.trim();
      final byMatch = _authorByPattern.firstMatch(trimmed);
      if (byMatch != null) return byMatch.group(1)?.trim();
      final authorMatch = _authorLabelPattern.firstMatch(trimmed);
      if (authorMatch != null) return authorMatch.group(1)?.trim();
    }
    return null;
  }

  /// Process extracted PDF text for XHTML: normalize line breaks, escape HTML,
  /// wrap paragraphs in <p>, preserve single line breaks as <br/>
  String _processPdfText(String textContent) {
    final normalized =
        textContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final escaped = _escapeHtml(normalized);
    final paragraphs = escaped.split(_paragraphSplitPattern);

    final buffer = StringBuffer();
    for (final paragraph in paragraphs) {
      final trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      final paragraphContent = trimmed.replaceAll('\n', '<br/>');
      buffer.writeln('<p>$paragraphContent</p>');
    }
    return buffer.toString();
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  Archive _createEpubArchive(PdfToEpubMetadata metadata, String processedContent) {
    final archive = Archive();
    final mimetypeBytes = utf8.encode(_mimetypeEpubZip);
    final mimetypeFile = ArchiveFile(
      'mimetype',
      mimetypeBytes.length,
      mimetypeBytes,
    );
    mimetypeFile.compress = false;
    archive.addFile(mimetypeFile);

    const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    _addUtf8File(archive, 'META-INF/container.xml', containerXml);

    _addUtf8File(archive, 'OEBPS/content.opf', _createContentOpf(metadata));
    _addUtf8File(archive, 'OEBPS/toc.ncx', _createTocNcx(metadata));
    _addUtf8File(archive, 'OEBPS/nav.xhtml', _createNavXhtml(metadata));
    _addUtf8File(
      archive,
      'OEBPS/chapter1.xhtml',
      _createChapterXhtml(metadata, processedContent),
    );

    return archive;
  }

  void _addUtf8File(Archive archive, String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  String _createContentOpf(PdfToEpubMetadata metadata) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>${_escapeHtml(metadata.title)}</dc:title>
    <dc:creator>${_escapeHtml(metadata.author)}</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="bookid">urn:uuid:${DateTime.now().millisecondsSinceEpoch}</dc:identifier>
    <meta property="dcterms:modified">${DateTime.now().toUtc().toIso8601String()}</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter1"/>
  </spine>
</package>''';
  }

  String _createTocNcx(PdfToEpubMetadata metadata) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:${DateTime.now().millisecondsSinceEpoch}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>${_escapeHtml(metadata.title)}</text>
  </docTitle>
  <navMap>
    <navPoint id="chapter1" playOrder="1">
      <navLabel>
        <text>${_escapeHtml(metadata.title)}</text>
      </navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
  }

  String _createNavXhtml(PdfToEpubMetadata metadata) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
  <title>Table of Contents</title>
  <meta charset="UTF-8"/>
</head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>Table of Contents</h1>
    <ol>
      <li>
        <a href="chapter1.xhtml">${_escapeHtml(metadata.title)}</a>
      </li>
    </ol>
  </nav>
</body>
</html>''';
  }

  String _createChapterXhtml(PdfToEpubMetadata metadata, String processedContent) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
  <title>${_escapeHtml(metadata.title)}</title>
  <meta charset="UTF-8"/>
</head>
<body>
  <section epub:type="bodymatter chapter">
    $processedContent
  </section>
</body>
</html>''';
  }
}

/// Metadata extracted from PDF file
class PdfToEpubMetadata {
  final String title;
  final String author;

  const PdfToEpubMetadata({
    required this.title,
    required this.author,
  });
}
