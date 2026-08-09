import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/models/reading_boundary.dart';
import 'package:memoreader/services/rag_context_builder.dart';

RagChunk _chunk(String id, int start, String text) => RagChunk(
  chunkId: id,
  bookId: 'book',
  text: text,
  embedding: Float32List(0),
  embeddingDimension: 0,
  charStart: start,
  charEnd: start + text.length,
  tokenStart: 0,
  tokenEnd: text.length,
  createdAt: DateTime.utc(2026),
);

void main() {
  const builder = RagContextBuilder();

  test('clips a crossing chunk at the exact exclusive reader boundary', () {
    final safe = builder.clipAndDeduplicate([
      _chunk('crossing', 10, 'abcdefghij'),
    ], boundary: const ReadingBoundary(lastVisibleExclusive: 16));
    expect(safe.single.text, 'abcdef');
    expect(safe.single.charEnd, 16);
  });

  test('removes configured overlap without dropping new text', () {
    final safe = builder.clipAndDeduplicate([
      _chunk('one', 0, 'abcdefghij'),
      _chunk('two', 6, 'ghijklmnop'),
    ]);
    expect(safe.map((chunk) => chunk.text), ['abcdefghij', 'klmnop']);
    expect(safe.map((chunk) => chunk.charStart), [0, 10]);
  });
}
