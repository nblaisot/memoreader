import 'dart:io';

import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'rag_token_budget.dart';

import '../models/rag_chunk.dart';
import '../utils/sentence_segmenter.dart';
import 'canonical_book_text_service.dart';

/// Chunks the canonical EPUB projection without inventing a second offset
/// coordinate system.
class RagChunkingService {
  RagChunkingService({
    required this.minTokens,
    required this.maxTokens,
    required this.overlapTokens,
    this.conservativeTokenCount = false,
    CanonicalBookTextService? canonicalTextService,
  }) : _canonicalTextService =
           canonicalTextService ?? const CanonicalBookTextService();

  static const int chunkingVersion = 4;

  final CanonicalBookTextService _canonicalTextService;
  final int minTokens;
  final int maxTokens;
  final int overlapTokens;
  final bool conservativeTokenCount;

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
      globalTokenOffset += _wordCount(section.text);
    }

    if (kDebugMode) {
      debugPrint(
        '[RAG] Canonical chunking: ${projection.sections.length} sections, '
        '${projection.text.length} chars, ${chunks.length} chunks, '
        'hash=${projection.contentHash.length > 12 ? projection.contentHash.substring(0, 12) : projection.contentHash}',
      );
    }
    return [
      for (var i = 0; i < chunks.length; i++)
        chunks[i].copyWith(
          previousChunkId:
              i > 0 && chunks[i - 1].sectionIndex == chunks[i].sectionIndex
              ? chunks[i - 1].chunkId
              : null,
          nextChunkId:
              i + 1 < chunks.length &&
                  chunks[i + 1].sectionIndex == chunks[i].sectionIndex
              ? chunks[i + 1].chunkId
              : null,
        ),
    ];
  }

  List<RagChunk> _chunkSection({
    required String bookId,
    required CanonicalBookSection section,
    required int globalTokenOffset,
  }) {
    final spans = SentenceSegmenter.split(section.text);
    if (spans.isEmpty) return [];

    final counts = [for (final span in spans) _wordCount(span.text)];
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
        if (tokenCount >= minTokens &&
            RegExp(r'^\s*\n\s*\n').hasMatch(
              section.text.substring(
                spans[endSentence].start,
                spans[endSentence].end,
              ),
            )) {
          break;
        }
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
    final chunks = <RagChunk>[];
    final text = span.text;
    int safeBoundary(int offset) {
      if (offset > 0 &&
          offset < text.length &&
          text.codeUnitAt(offset) >= 0xDC00 &&
          text.codeUnitAt(offset) <= 0xDFFF) {
        return offset - 1;
      }
      return offset;
    }

    var start = 0;
    while (start < text.length) {
      var low = start + 1, high = text.length, end = start + 1;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        if (_wordCount(text.substring(start, mid)) <= maxTokens) {
          end = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      end = safeBoundary(end);
      if (end <= start) end = (start + 2).clamp(0, text.length);
      chunks.add(
        _createChunk(
          bookId: bookId,
          section: section,
          localStart: span.start + start,
          localEnd: span.start + end,
          tokenStart: globalTokenOffset + _wordCount(text.substring(0, start)),
        ),
      );
      if (end >= text.length) break;
      low = start + 1;
      high = end;
      var next = end;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        if (_wordCount(text.substring(mid, end)) <= overlapTokens) {
          next = mid;
          high = mid - 1;
        } else {
          low = mid + 1;
        }
      }
      next = safeBoundary(next);
      start = next <= start ? end : next;
    }
    return chunks;
  }

  static String projectionIdentity(CanonicalBookSection s) =>
      '${s.sectionIndex}:${s.contentFileKey}';

  RagChunk _createChunk({
    required String bookId,
    required CanonicalBookSection section,
    required int localStart,
    required int localEnd,
    required int tokenStart,
  }) {
    final text = section.text.substring(localStart, localEnd);
    return RagChunk(
      chunkId: sha256
          .convert(
            utf8.encode(
              '$bookId:${projectionIdentity(section)}:${section.charStart + localStart}:${section.charStart + localEnd}:$chunkingVersion:$text',
            ),
          )
          .toString(),
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
      tokenEnd: tokenStart + _wordCount(text),
      createdAt: DateTime.now(),
    );
  }

  int _wordCount(String text) =>
      RagTokenBudget.count(text, conservative: conservativeTokenCount);
}
