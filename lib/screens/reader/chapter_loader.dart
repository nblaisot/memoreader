import 'dart:io';
import 'dart:typed_data';

import 'package:epubx/epubx.dart';
import 'package:image/image.dart' as img;

import '../../models/book.dart';
import 'html_block_parser.dart';
import 'html_blocks.dart';

class ChapterData {
  ChapterData({
    required this.index,
    required this.title,
    required this.blocks,
  });

  final int index;
  final String title;
  final List<HtmlBlock> blocks;
}

class ChapterLoader {
  ChapterLoader({HtmlBlockParser? parser}) : _parser = parser ?? const HtmlBlockParser();

  final HtmlBlockParser _parser;

  Future<List<ChapterData>> load(Book book) async {
    final epub = await EpubReader.readBook(await File(book.filePath).readAsBytes());
    final images = epub.Content?.Images ?? const <String, EpubByteContentFile>{};
    final chapters = epub.Chapters ?? const <EpubChapter>[];

    final results = <ChapterData>[];

    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final html = chapter.HtmlContent ?? '';
      if (html.trim().isEmpty) {
        continue;
      }

      final blocks = _parser.parse(html).map((block) {
        if (block is ImageBlock) {
          final resolved = _resolveImage(block.source, images);
          if (resolved != null) {
            return ImageBlock(
              bytes: resolved.bytes,
              source: block.source,
              intrinsicWidth: resolved.width,
              intrinsicHeight: resolved.height,
              spacingBefore: block.spacingBefore,
              spacingAfter: block.spacingAfter,
            );
          }
        }
        return block;
      }).toList();

      if (blocks.isEmpty) continue;

      results.add(
        ChapterData(
          index: i,
          title: (chapter.Title ?? 'Chapter ${i + 1}').trim(),
          blocks: blocks,
        ),
      );
    }

    if (results.isEmpty) {
      results.add(
        ChapterData(
          index: 0,
          title: book.title,
          blocks: [ParagraphBlock(text: 'Aucun contenu lisible dans ce livre.')],
        ),
      );
    }

    return results;
  }

  _ResolvedImage? _resolveImage(
    String? source,
    Map<String, EpubByteContentFile> images,
  ) {
    if (source == null) return null;
    var normalized = source.replaceAll('\\', '/');
    normalized = normalized.replaceAll('../', '');
    final keyFragment = normalized.split('/').last;

    for (final entry in images.entries) {
      final key = entry.key.replaceAll('\\', '/');
      if (key.endsWith(keyFragment)) {
        final bytes = entry.value.Content;
        if (bytes == null) return null;
        double? width;
        double? height;
        try {
          final decoded = img.decodeImage(bytes);
          if (decoded != null) {
            width = decoded.width.toDouble();
            height = decoded.height.toDouble();
          }
        } catch (_) {
          width = null;
          height = null;
        }
        return _ResolvedImage(
          bytes: Uint8List.fromList(bytes),
          width: width,
          height: height,
        );
      }
    }
    return null;
  }
}

class _ResolvedImage {
  _ResolvedImage({required this.bytes, this.width, this.height});

  final Uint8List bytes;
  final double? width;
  final double? height;
}
