import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

/// Service for converting plain text files to EPUB format
/// 
/// Creates a minimal but valid EPUB 3.0 structure with a single chapter
/// containing all the text content. The EPUB can then be processed like
/// any other EPUB file in the app.
class TxtToEpubConverter {
  /// Convert a TXT file to EPUB format and save it to the specified path
  /// 
  /// Returns metadata extracted from the file (title, author)
  Future<TxtToEpubMetadata> convertToEpub({
    required File txtFile,
    required String outputEpubPath,
  }) async {
    try {
      // Read the TXT file content
      final textContent = await txtFile.readAsString();
      
      // Extract metadata from filename and content
      final metadata = _extractMetadata(txtFile.path, textContent);
      
      // Process the text content for XHTML
      final processedContent = _processTextContent(textContent);
      
      // Create the EPUB structure
      final archive = _createEpubArchive(metadata, processedContent);
      
      // Save the EPUB file
      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) {
        throw Exception('Failed to encode EPUB archive');
      }
      
      final outputFile = File(outputEpubPath);
      await outputFile.writeAsBytes(zipBytes);
      
      debugPrint('TXT to EPUB conversion successful: $outputEpubPath');
      return metadata;
    } catch (e) {
      debugPrint('Error converting TXT to EPUB: $e');
      rethrow;
    }
  }
  
  /// Extract metadata (title, author) from filename and text content
  TxtToEpubMetadata _extractMetadata(String filePath, String textContent) {
    // Extract filename without path and extension
    final filename = filePath.split('/').last.split('\\').last;
    final filenameWithoutExt = filename.contains('.')
        ? filename.substring(0, filename.lastIndexOf('.'))
        : filename;
    
    // Clean up filename to use as title
    String title = filenameWithoutExt
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .trim();
    
    // Capitalize first letter of each word
    if (title.isNotEmpty) {
      title = title.split(' ')
          .map((word) => word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1))
          .join(' ');
    }
    
    // If title is empty, use default
    if (title.isEmpty) {
      title = 'Unknown Title';
    }
    
    // Try to extract author from content (look for common patterns)
    String? author;
    final lines = textContent.split('\n').take(10).toList(); // Check first 10 lines
    
    for (final line in lines) {
      final trimmedLine = line.trim();
      
      // Pattern: "By Author Name" or "by Author Name"
      if (RegExp(r'^by\s+(.+)$', caseSensitive: false).hasMatch(trimmedLine)) {
        final match = RegExp(r'^by\s+(.+)$', caseSensitive: false).firstMatch(trimmedLine);
        author = match?.group(1)?.trim();
        break;
      }
      
      // Pattern: "Author: Name"
      if (RegExp(r'^author[:\s]+(.+)$', caseSensitive: false).hasMatch(trimmedLine)) {
        final match = RegExp(r'^author[:\s]+(.+)$', caseSensitive: false).firstMatch(trimmedLine);
        author = match?.group(1)?.trim();
        break;
      }
    }
    
    // If we found a potential title in first line and it's short, use it as title
    if (lines.isNotEmpty) {
      final firstLine = lines.first.trim();
      if (firstLine.isNotEmpty && firstLine.length < 100 && !firstLine.contains('\t')) {
        // If it looks like a title (short, no tabs, not a sentence)
        if (!firstLine.endsWith('.') || firstLine.split(' ').length <= 8) {
          title = firstLine;
        }
      }
    }
    
    return TxtToEpubMetadata(
      title: title,
      author: author ?? 'Unknown Author',
    );
  }
  
  /// Process text content for XHTML
  /// - Normalize line breaks
  /// - Escape HTML entities
  /// - Wrap paragraphs in <p> tags
  String _processTextContent(String textContent) {
    // Normalize line breaks (handle \r\n, \r, \n)
    String normalized = textContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    
    // Escape HTML entities
    normalized = _escapeHtml(normalized);
    
    // Split into paragraphs (double line breaks)
    final paragraphs = normalized.split('\n\n');
    
    final buffer = StringBuffer();
    for (final paragraph in paragraphs) {
      final trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      
      // Replace single line breaks with <br/> within paragraph
      final paragraphContent = trimmed.replaceAll('\n', '<br/>');
      
      buffer.writeln('<p>$paragraphContent</p>');
    }
    
    return buffer.toString();
  }
  
  /// Escape HTML entities
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
  
  /// Create the EPUB archive structure
  Archive _createEpubArchive(TxtToEpubMetadata metadata, String processedContent) {
    final archive = Archive();
    
    // 1. mimetype file (MUST be first, uncompressed)
    final mimetypeBytes = utf8.encode('application/epub+zip');
    final mimetypeFile = ArchiveFile(
      'mimetype',
      mimetypeBytes.length,
      mimetypeBytes,
    );
    mimetypeFile.compress = false; // MUST be stored uncompressed
    archive.addFile(mimetypeFile);
    
    // 2. META-INF/container.xml
    final containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    
    final containerBytes = utf8.encode(containerXml);
    archive.addFile(ArchiveFile(
      'META-INF/container.xml',
      containerBytes.length,
      containerBytes,
    ));
    
    // 3. OEBPS/content.opf (package document)
    final contentOpf = _createContentOpf(metadata);
    final contentOpfBytes = utf8.encode(contentOpf);
    archive.addFile(ArchiveFile(
      'OEBPS/content.opf',
      contentOpfBytes.length,
      contentOpfBytes,
    ));
    
    // 4. OEBPS/toc.ncx (navigation)
    final tocNcx = _createTocNcx(metadata);
    final tocNcxBytes = utf8.encode(tocNcx);
    archive.addFile(ArchiveFile(
      'OEBPS/toc.ncx',
      tocNcxBytes.length,
      tocNcxBytes,
    ));
    
    // 5. OEBPS/nav.xhtml (EPUB 3 navigation document)
    final navXhtml = _createNavXhtml(metadata);
    final navXhtmlBytes = utf8.encode(navXhtml);
    archive.addFile(ArchiveFile(
      'OEBPS/nav.xhtml',
      navXhtmlBytes.length,
      navXhtmlBytes,
    ));
    
    // 6. OEBPS/chapter1.xhtml (content)
    final chapterXhtml = _createChapterXhtml(metadata, processedContent);
    final chapterXhtmlBytes = utf8.encode(chapterXhtml);
    archive.addFile(ArchiveFile(
      'OEBPS/chapter1.xhtml',
      chapterXhtmlBytes.length,
      chapterXhtmlBytes,
    ));
    
    return archive;
  }
  
  /// Create content.opf (package document)
  String _createContentOpf(TxtToEpubMetadata metadata) {
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
  
  /// Create toc.ncx (navigation for EPUB 2 compatibility)
  String _createTocNcx(TxtToEpubMetadata metadata) {
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
  
  /// Create nav.xhtml (EPUB 3 navigation document)
  String _createNavXhtml(TxtToEpubMetadata metadata) {
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
  
  /// Create chapter1.xhtml (content)
  String _createChapterXhtml(TxtToEpubMetadata metadata, String processedContent) {
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

/// Metadata extracted from TXT file
class TxtToEpubMetadata {
  final String title;
  final String author;
  
  const TxtToEpubMetadata({
    required this.title,
    required this.author,
  });
}

