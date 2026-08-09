import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/rag_chunk.dart';
import '../utils/sentence_segmenter.dart';
import '../utils/text_tokenizer.dart';
import 'canonical_book_text_service.dart';

/// Chunks the canonical EPUB projection without inventing a second offset
/// coordinate system.
class RagChunkingService {
  RagChunkingService({
    required this.minTokens,
    required this.maxTokens,
    required this.overlapTokens,
    CanonicalBookTextService? canonicalTextService,
  }) : _canonicalTextService =
           canonicalTextService ?? const CanonicalBookTextService();

  static const int chunkingVersion = 2;

  final Uuid _uuid = const Uuid();
  final CanonicalBookTextService _canonicalTextService;
  final int minTokens;
  final int maxTokens;
  final int overlapTokens;

  Future<List<RagChunk>> chunkBook({
    required File epubFile,
    required String bookId,
  }) async {
    return chunkCanonicalBook(
      projection: await _canonicalTextService.fromFile(epubFile),
      bookId: bookId,
    );
  }

  List<RagChunk> chunkCanonicalBook({
    required CanonicalBookText projection,
    required String bookId,
  }) {
    final chunks = <RagChunk>[];
    var globalTokenOffset = 0;

    for (final section in projection.sections) {
      final sectionChunks = _chunkSection(
        bookId: bookId,
        section: section,
        globalTokenOffset: globalTokenOffset,
      );
      chunks.addAll(sectionChunks);
      globalTokenOffset += tokenizePreservingWhitespace(section.text).length;
    }

    if (kDebugMode) {
      debugPrint(
        '[RAG] Canonical chunking: ${projection.sections.length} sections, '
        '${projection.text.length} chars, ${chunks.length} chunks, '
        'hash=${projection.contentHash.length > 12 ? projection.contentHash.substring(0, 12) : projection.contentHash}',
      );
    }
    return chunks;
  }

  List<RagChunk> _chunkSection({
    required String bookId,
    required CanonicalBookSection section,
    required int globalTokenOffset,
  }) {
    final spans = SentenceSegmenter.split(section.text);
    if (spans.isEmpty) return [];

    final counts = [
      for (final span in spans) tokenizePreservingWhitespace(span.text).length,
    ];
    final chunks = <RagChunk>[];
    var startSentence = 0;

    while (startSentence < spans.length) {
      while (startSentence < spans.length && counts[startSentence] == 0) {
        startSentence++;
      }
      if (startSentence >= spans.length) break;

      if (counts[startSentence] > maxTokens) {
        chunks.addAll(
          _splitLongSentence(
            bookId: bookId,
            section: section,
            span: spans[startSentence],
            globalTokenOffset:
                globalTokenOffset +
                counts.take(startSentence).fold<int>(0, (a, b) => a + b),
          ),
        );
        startSentence++;
        continue;
      }

      var endSentence = startSentence;
      var tokenCount = 0;
      while (endSentence < spans.length) {
        final next = counts[endSentence];
        if (next > maxTokens ||
            (tokenCount > 0 && tokenCount + next > maxTokens)) {
          break;
        }
        tokenCount += next;
        endSentence++;
      }
      if (endSentence == startSentence) endSentence++;

      // Merge a small final tail when it still fits.
      while (endSentence < spans.length && tokenCount < minTokens) {
        final next = counts[endSentence];
        if (tokenCount + next > maxTokens) break;
        tokenCount += next;
        endSentence++;
      }

      chunks.add(
        _createChunk(
          bookId: bookId,
          section: section,
          localStart: spans[startSentence].start,
          localEnd: spans[endSentence - 1].end,
          tokenStart:
              globalTokenOffset +
              counts.take(startSentence).fold<int>(0, (a, b) => a + b),
        ),
      );

      if (endSentence >= spans.length) break;

      // Real textual overlap: rewind whole sentences while staying below the
      // requested overlap. Always make forward progress.
      var nextStart = endSentence;
      var overlap = 0;
      while (nextStart > startSentence + 1) {
        final previous = counts[nextStart - 1];
        if (overlap > 0 && overlap + previous > overlapTokens) break;
        if (overlapTokens == 0) break;
        overlap += previous;
        nextStart--;
        if (overlap >= overlapTokens) break;
      }
      startSentence = nextStart < endSentence ? nextStart : endSentence;
    }
    return chunks;
  }

  List<RagChunk> _splitLongSentence({
    required String bookId,
    required CanonicalBookSection section,
    required SentenceSpan span,
    required int globalTokenOffset,
  }) {
    final tokens = tokenizePreservingWhitespace(span.text);
    final chunks = <RagChunk>[];
    var startToken = 0;
    while (startToken < tokens.length) {
      final endToken = (startToken + maxTokens).clamp(0, tokens.length);
      final prefixLength = tokens
          .take(startToken)
          .fold<int>(0, (length, token) => length + token.length);
      final textLength = tokens
          .skip(startToken)
          .take(endToken - startToken)
          .fold<int>(0, (length, token) => length + token.length);
      chunks.add(
        _createChunk(
          bookId: bookId,
          section: section,
          localStart: span.start + prefixLength,
          localEnd: span.start + prefixLength + textLength,
          tokenStart: globalTokenOffset + startToken,
        ),
      );
      if (endToken == tokens.length) break;
      startToken = (endToken - overlapTokens).clamp(startToken + 1, endToken);
    }
    return chunks;
  }

  RagChunk _createChunk({
    required String bookId,
    required CanonicalBookSection section,
    required int localStart,
    required int localEnd,
    required int tokenStart,
  }) {
    final text = section.text.substring(localStart, localEnd);
    return RagChunk(
      chunkId: _uuid.v4(),
      bookId: bookId,
      text: text,
      embedding: Float32List(0),
      embeddingDimension: 0,
      chapterIndex: section.chapterIndex,
      chapterTitle: section.chapterTitle,
      sectionIndex: section.sectionIndex,
      contentFileKey: section.contentFileKey,
      charStart: section.charStart + localStart,
      charEnd: section.charStart + localEnd,
      tokenStart: tokenStart,
      tokenEnd: tokenStart + tokenizePreservingWhitespace(text).length,
      createdAt: DateTime.now(),
    );
  }
}
