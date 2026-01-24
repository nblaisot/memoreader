import 'dart:io';
import 'dart:typed_data';

import 'package:epubx/epubx.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/rag_chunk.dart';
import '../utils/html_text_extractor.dart';
import '../utils/sentence_segmenter.dart';
import '../utils/text_tokenizer.dart';

/// Service for chunking book text into RAG-ready chunks.
///
/// Chunking is performed per chapter, at sentence granularity, with token‑based
/// minimum/maximum sizes and configurable overlap. All chunks are guaranteed
/// to stay within a single chapter and to respect the configured token bounds.
class RagChunkingService {
  RagChunkingService({
    required this.minTokens,
    required this.maxTokens,
    required this.overlapTokens,
  });

  final Uuid _uuid = const Uuid();

  /// Minimum number of tokens per chunk (where possible).
  final int minTokens;

  /// Maximum number of tokens per chunk (must be <= the embedding model's
  /// maxTokensPerInput minus any safety margin).
  final int maxTokens;

  /// Desired amount of token overlap between adjacent chunks.
  final int overlapTokens;

  /// Chunk a book from its EPUB file into a flat list of [RagChunk]s.
  ///
  /// The returned chunks:
  ///  * are built at sentence granularity,
  ///  * never cross chapter boundaries,
  ///  * and carry `chapterIndex`, `charStart/charEnd`, and `tokenStart/tokenEnd`.
  Future<List<RagChunk>> chunkBook({
    required File epubFile,
    required String bookId,
  }) async {
    if (kDebugMode) {
      debugPrint('[RAG] Starting chunkBook for book $bookId');
    }
    final epubBytes = await epubFile.readAsBytes();
    final epub = await EpubReader.readBook(epubBytes);

    // First, try processing chapters from epub.Chapters
    final chapters = _flattenChapters(epub.Chapters ?? const <EpubChapter>[]);
    if (kDebugMode) {
      debugPrint('[RAG] Found ${chapters.length} chapters in EPUB');
    }
    final chunks = <RagChunk>[];

    int globalTokenOffset = 0;
    int globalCharOffset = 0;
    int processedChapters = 0;
    int skippedChapters = 0;

    for (var chapterIndex = 0; chapterIndex < chapters.length; chapterIndex++) {
      final chapter = chapters[chapterIndex];
      String chapterText;
      try {
        final html = chapter.HtmlContent;
        if (html == null || html.isEmpty) {
          skippedChapters++;
          if (kDebugMode) {
            debugPrint('[RAG] Chapter $chapterIndex: HTML content is null or empty, skipping');
          }
          continue;
        }
        chapterText = HtmlTextExtractor.extract(html).trimRight();
      } catch (e) {
        skippedChapters++;
        if (kDebugMode) {
          debugPrint('[RAG] Failed to extract text for chapter $chapterIndex: $e');
        }
        continue;
      }

      if (chapterText.isEmpty) {
        skippedChapters++;
        if (kDebugMode) {
          debugPrint('[RAG] Chapter $chapterIndex: Extracted text is empty, skipping');
        }
        continue;
      }

      processedChapters++;
      if (kDebugMode && chapterIndex % 10 == 0) {
        debugPrint('[RAG] Chapter $chapterIndex: ${chapterText.length} characters, ${chapterText.split(RegExp(r'\s+')).length} words');
      }

      final chapterChunks = _chunkChapter(
        bookId: bookId,
        chapterIndex: chapterIndex,
        chapterText: chapterText,
        chapterCharOffset: globalCharOffset,
        globalTokenOffset: globalTokenOffset,
      );

      if (chapterChunks.isNotEmpty) {
        chunks.addAll(chapterChunks);
        globalTokenOffset = chapterChunks.last.tokenEnd - overlapTokens;
        if (globalTokenOffset < 0) {
          globalTokenOffset = 0;
        }
      }
      globalCharOffset += chapterText.length;
    }

    if (kDebugMode) {
      debugPrint('[RAG] Chunking summary: ${chapters.length} total chapters, $processedChapters processed, $skippedChapters skipped, ${chunks.length} chunks so far');
    }

    // If no chunks were produced from chapters, fall back to epub.Content?.Html
    // (same fallback logic as the summary service uses)
    if (chunks.isEmpty) {
      if (kDebugMode) {
        debugPrint('[RAG] No chunks from chapters, falling back to epub.Content?.Html');
      }
      final htmlFiles = epub.Content?.Html;
      if (htmlFiles != null && htmlFiles.isNotEmpty) {
        final entries = htmlFiles.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        
        for (var i = 0; i < entries.length; i++) {
          final file = entries[i].value;
          final htmlContent = file.Content ?? '';
          if (htmlContent.isEmpty) {
            continue;
          }
          
          try {
            final sectionText = HtmlTextExtractor.extract(htmlContent).trimRight();
            if (sectionText.isEmpty) {
              continue;
            }
            
            final sectionChunks = _chunkChapter(
              bookId: bookId,
              chapterIndex: i,
              chapterText: sectionText,
              chapterCharOffset: globalCharOffset,
              globalTokenOffset: globalTokenOffset,
            );
            
            if (sectionChunks.isNotEmpty) {
              chunks.addAll(sectionChunks);
              globalTokenOffset = sectionChunks.last.tokenEnd - overlapTokens;
              if (globalTokenOffset < 0) {
                globalTokenOffset = 0;
              }
            }
            globalCharOffset += sectionText.length;
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[RAG] Failed to extract text from HTML file ${entries[i].key}: $e');
            }
            continue;
          }
        }
        
        if (kDebugMode) {
          debugPrint('[RAG] Fallback: Processed ${entries.length} HTML files from epub.Content?.Html');
        }
      }
    }

    if (kDebugMode) {
      final totalTokens = chunks.isEmpty
          ? 0
          : chunks.last.tokenEnd;
      final minSize = chunks.isEmpty
          ? 0
          : chunks.map((c) => c.tokenEnd - c.tokenStart).reduce((a, b) => a < b ? a : b);
      final maxSize = chunks.isEmpty
          ? 0
          : chunks.map((c) => c.tokenEnd - c.tokenStart).reduce((a, b) => a > b ? a : b);
      debugPrint(
        '[RAG] Chunked book into ${chunks.length} chunks, tokens: total=$totalTokens, '
        'min=$minSize, max=$maxSize, minTokens=$minTokens, maxTokens=$maxTokens',
      );
    }

    return chunks;
  }

  /// Flatten a potentially nested chapter tree into a single ordered list.
  List<EpubChapter> _flattenChapters(List<EpubChapter> chapters) {
    final result = <EpubChapter>[];
    for (final chapter in chapters) {
      result.add(chapter);
      if (chapter.SubChapters != null && chapter.SubChapters!.isNotEmpty) {
        result.addAll(_flattenChapters(chapter.SubChapters!));
      }
    }
    return result;
  }

  /// Chunk a single chapter into [RagChunk]s.
  List<RagChunk> _chunkChapter({
    required String bookId,
    required int chapterIndex,
    required String chapterText,
    required int chapterCharOffset,
    required int globalTokenOffset,
  }) {
    final chunks = <RagChunk>[];

    // Segment chapter into sentences with character spans.
    final sentenceSpans = SentenceSegmenter.split(chapterText);
    if (sentenceSpans.isEmpty) {
      return chunks;
    }

    // Pre-compute tokenised sentences for efficiency.
    final sentenceTokens = <List<String>>[];
    for (final span in sentenceSpans) {
      final tokens = tokenizePreservingWhitespace(span.text);
      if (tokens.isEmpty) {
        sentenceTokens.add(const []);
      } else {
        sentenceTokens.add(tokens);
      }
    }

    int sentenceIndex = 0;

    while (sentenceIndex < sentenceSpans.length) {
      // Skip empty sentences defensively.
      while (sentenceIndex < sentenceSpans.length &&
          sentenceTokens[sentenceIndex].isEmpty) {
        sentenceIndex++;
      }
      if (sentenceIndex >= sentenceSpans.length) break;

      int startIndex = sentenceIndex;
      int endIndex = sentenceIndex;
      int chunkTokenCount = 0;

      // Seed with the first sentence.
      final firstTokens = sentenceTokens[sentenceIndex];
      if (firstTokens.length > maxTokens) {
        // Split this single very long sentence into multiple chunks.
        final split = _splitSentence(
          bookId: bookId,
          chapterIndex: chapterIndex,
          chapterText: chapterText,
          chapterCharOffset: chapterCharOffset,
          span: sentenceSpans[sentenceIndex],
          tokens: firstTokens,
          globalTokenOffset: globalTokenOffset,
        );
        chunks.addAll(split);
        if (split.isNotEmpty) {
          globalTokenOffset = split.last.tokenEnd - overlapTokens;
          if (globalTokenOffset < 0) globalTokenOffset = 0;
        }
        sentenceIndex++;
        continue;
      }

      chunkTokenCount = firstTokens.length;
      endIndex = sentenceIndex + 1;

      // Grow the chunk by adding more sentences up to [maxTokens].
      while (endIndex < sentenceSpans.length) {
        final tokens = sentenceTokens[endIndex];
        if (tokens.isEmpty) {
          endIndex++;
          continue;
        }

        final additional = tokens.length + 1; // assume one separator token
        if (chunkTokenCount + additional > maxTokens) {
          break;
        }

        chunkTokenCount += additional;
        endIndex++;
        if (chunkTokenCount >= maxTokens) break;
      }

      // If we ended up with a very small chunk at the end of the chapter,
      // try to merge it backwards with previous sentences (increasing overlap).
      if (chunkTokenCount < minTokens && endIndex == sentenceSpans.length) {
        int backIndex = startIndex - 1;
        while (backIndex >= 0 && chunkTokenCount < minTokens) {
          final tokens = sentenceTokens[backIndex];
          if (tokens.isEmpty) {
            backIndex--;
            continue;
          }
          final additional = tokens.length + 1;
          if (chunkTokenCount + additional > maxTokens) {
            break;
          }
          chunkTokenCount += additional;
          startIndex = backIndex;
          backIndex--;
        }
      }

      final localCharStart = sentenceSpans[startIndex].start;
      final localCharEnd = sentenceSpans[endIndex - 1].end;
      final charStart = chapterCharOffset + localCharStart;
      final charEnd = chapterCharOffset + localCharEnd;
      final chunkText =
          chapterText.substring(localCharStart, localCharEnd).trimRight();

      if (chunkText.isEmpty) {
        sentenceIndex = endIndex;
        continue;
      }

      final tokens = tokenizePreservingWhitespace(chunkText);
      int tokenStart = globalTokenOffset;
      int tokenEnd = globalTokenOffset + tokens.length;

      if (chunks.isNotEmpty && overlapTokens > 0) {
        tokenStart = tokenStart - overlapTokens;
        if (tokenStart < 0) tokenStart = 0;
      }

      final chunk = RagChunk(
        chunkId: _uuid.v4(),
        bookId: bookId,
        text: chunkText,
        embedding: Float32List(0),
        embeddingDimension: 0,
        chapterIndex: chapterIndex,
        charStart: charStart,
        charEnd: charEnd,
        tokenStart: tokenStart,
        tokenEnd: tokenEnd,
        createdAt: DateTime.now(),
      );

      chunks.add(chunk);

      globalTokenOffset = tokenEnd - overlapTokens;
      if (globalTokenOffset < 0) globalTokenOffset = 0;

      sentenceIndex = endIndex;
    }

    return chunks;
  }

  /// Split an oversized sentence into multiple chunks that each respect
  /// [maxTokens].
  List<RagChunk> _splitSentence({
    required String bookId,
    required int chapterIndex,
    required String chapterText,
    required int chapterCharOffset,
    required SentenceSpan span,
    required List<String> tokens,
    required int globalTokenOffset,
  }) {
    final chunks = <RagChunk>[];

    int tokenIndex = 0;
    int currentGlobalTokenOffset = globalTokenOffset;

    while (tokenIndex < tokens.length) {
      int count = 0;
      int startToken = tokenIndex;
      int endToken = tokenIndex;

      while (endToken < tokens.length && count < maxTokens) {
        count++;
        endToken++;
      }

      // Derive character offsets from token lengths within the sentence.
      int localCharStart = 0;
      for (int i = 0; i < startToken; i++) {
        localCharStart += tokens[i].length;
      }
      int localCharEnd = localCharStart;
      for (int i = startToken; i < endToken; i++) {
        localCharEnd += tokens[i].length;
      }

      final localStart = span.start + localCharStart;
      final localEnd = span.start + localCharEnd;
      final charStart = chapterCharOffset + localStart;
      final charEnd = chapterCharOffset + localEnd;

      final chunkText = chapterText.substring(localStart, localEnd);
      final chunkTokens = tokenizePreservingWhitespace(chunkText);

      int tokenStart = currentGlobalTokenOffset;
      int tokenEnd = currentGlobalTokenOffset + chunkTokens.length;

      if (chunks.isNotEmpty && overlapTokens > 0) {
        tokenStart = currentGlobalTokenOffset - overlapTokens;
        if (tokenStart < 0) tokenStart = 0;
      }

      final chunk = RagChunk(
        chunkId: _uuid.v4(),
        bookId: bookId,
        text: chunkText,
        embedding: Float32List(0),
        embeddingDimension: 0,
        chapterIndex: chapterIndex,
        charStart: charStart,
        charEnd: charEnd,
        tokenStart: tokenStart,
        tokenEnd: tokenEnd,
        createdAt: DateTime.now(),
      );

      chunks.add(chunk);

      currentGlobalTokenOffset = tokenEnd - overlapTokens;
      if (currentGlobalTokenOffset < 0) currentGlobalTokenOffset = 0;
      tokenIndex = endToken;
    }

    return chunks;
  }
}
