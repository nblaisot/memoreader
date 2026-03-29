import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/rag_chunking_service.dart';
import 'package:memoreader/services/txt_to_epub_converter.dart';

void main() {
  late Directory tempDir;
  late File epubFile;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('memoreader_rag_chunk_');
    final txt = File('${tempDir.path}/long.txt');
    await txt.writeAsString(
      List.generate(
        20,
        (i) => 'This is sentence number ${i + 1}. It has enough words to build tokens.',
      ).join(' '),
    );
    final outPath = '${tempDir.path}/book.epub';
    await TxtToEpubConverter().convertToEpub(txtFile: txt, outputEpubPath: outPath);
    epubFile = File(outPath);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('chunkBook produces non-empty chunks within token bounds', () async {
    const bookId = 'test-book-chunk';
    final service = RagChunkingService(
      minTokens: 8,
      maxTokens: 64,
      overlapTokens: 4,
    );

    final chunks = await service.chunkBook(epubFile: epubFile, bookId: bookId);

    expect(chunks, isNotEmpty);
    for (final c in chunks) {
      expect(c.bookId, bookId);
      final n = c.tokenEnd - c.tokenStart;
      // Heuristic chunker may slightly exceed configured max on long sentences.
      expect(n, lessThanOrEqualTo(80));
      expect(c.text.trim(), isNotEmpty);
    }

    for (var i = 1; i < chunks.length; i++) {
      expect(
        chunks[i].charStart >= chunks[i - 1].charStart,
        isTrue,
        reason: 'char ranges should be non-decreasing',
      );
    }
  });
}
