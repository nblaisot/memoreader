import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:epubx/epubx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

import '../models/book.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../models/book_summary_chunk.dart';
import '../models/book_summary_cache.dart';
import '../models/structured_summary.dart';
import 'summary_database_service.dart';
import 'book_service.dart';
import 'summary_service.dart';
import 'openai_summary_service.dart';
import 'prompt_config_service.dart';
import 'api_cache_service.dart';
import '../utils/html_text_extractor.dart';

/// Represents text extracted from a chapter, possibly truncated.
class ChapterText {
  const ChapterText({
    required this.chapterIndex,
    required this.title,
    required this.text,
    required this.isComplete,
  });

  final int chapterIndex;
  final String title;
  final String text;
  final bool isComplete;
}

class _ChunkDefinition {
  const _ChunkDefinition({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    required this.hash,
  });

  final int index;
  final int start;
  final int end;
  final String text;
  final String hash;
}

class _PreparedTextData {
  const _PreparedTextData({
    required this.fullText,
    required this.chunks,
  });

  final String fullText;
  final List<_ChunkDefinition> chunks;
}

/// Configuration for chunking and batching text for summary generation.
/// 
/// Different summary providers have vastly different capabilities:
/// 
/// **OpenAI (GPT models)**:
/// - Context: 8K-128K tokens depending on model
/// - Strategy: Large chunks with generous overlap for context continuity
/// - Batching: Process multiple chapters per batch for efficient API usage
/// - Safety: High safety factor as API handles token management
/// 
/// **Mistral AI**:
/// - Context: 8K-32K tokens depending on model
/// - Strategy: Similar to OpenAI, good context windows
/// - Batching: Process multiple chapters per batch
/// - Safety: High safety factor
/// 
/// Token estimation: 1 token ≈ 4 characters (rough approximation)
class ChunkingConfig {
  /// Maximum tokens to process in a single chunk before splitting
  final int maxChunkTokens;
  
  /// Tokens to overlap between chunks for context continuity
  final int overlapTokens;
  
  /// Maximum chunks to process in a single batch
  final int maxChunksPerBatch;
  
  /// Maximum total tokens for aggregate operations (combining summaries)
  final int maxAggregateTokens;
  
  /// Safety factor applied to maxChunkTokens to provide buffer (0.0-1.0)
  final double safetyFactor;

  const ChunkingConfig({
    required this.maxChunkTokens,
    required this.overlapTokens,
    required this.maxChunksPerBatch,
    required this.maxAggregateTokens,
    this.safetyFactor = 0.75,
  });

  /// Safe chunk size accounting for safety margin
  int get safeChunkTokens =>
      math.max(512, (maxChunkTokens * safetyFactor).floor());

  /// Resolve appropriate configuration based on the summary service
  static ChunkingConfig resolve(SummaryService summaryService) {
    if (summaryService is OpenAISummaryService) {
      // OpenAI: Generous limits, efficient batch processing
      // Context size: 8K-128K tokens depending on model
      return const ChunkingConfig(
        maxChunkTokens: 3000,
        overlapTokens: 200,
        maxChunksPerBatch: 6,
        maxAggregateTokens: 15000,
        safetyFactor: 0.85,  // High safety factor
      );
    }

    // Import mistral_summary_service for type check
    // Note: We use runtime type check to avoid circular dependency
    final serviceName = summaryService.serviceName.toLowerCase();
    if (serviceName.contains('mistral')) {
      // Mistral: Similar to OpenAI, good context windows
      // Context size: 8K-32K tokens depending on model (mistral-small: 32K)
      return const ChunkingConfig(
        maxChunkTokens: 28000,
        overlapTokens: 400,
        maxChunksPerBatch: 6,
        maxAggregateTokens: 60000,  // Keep well below full context
        safetyFactor: 0.85,  // High safety factor
      );
    }

    // Default fallback for unknown providers
    return const ChunkingConfig(
      maxChunkTokens: 5000,
      overlapTokens: 180,
      maxChunksPerBatch: 4,
      maxAggregateTokens: 20000,
      safetyFactor: 0.75,
    );
  }
}

/// Enhanced summary service that provides three types of summaries:
/// 1. From beginning - cumulative summary of everything read so far
/// 2. Since last time - summary of the last reading session
/// 3. Characters - character summary with relationships
/// 
/// This service uses the underlying SummaryService (OpenAISummaryService or MistralSummaryService)
/// and adds database caching, incremental processing, and session tracking.
class EnhancedSummaryService {
  final SummaryService _baseSummaryService;
  final SummaryDatabaseService _dbService = SummaryDatabaseService();
  final BookService _bookService = BookService();
  final ChunkingConfig _chunkConfig;
  final PromptConfigService _promptConfigService;

  static const int _charactersPerToken = 4;

  int get _maxTokensPerChunk => _chunkConfig.maxChunkTokens;
  int get _chunkOverlapTokens => _chunkConfig.overlapTokens;
  int get _maxChunksPerBatch => _chunkConfig.maxChunksPerBatch;
  int get _maxCumulativeTokens => _chunkConfig.maxAggregateTokens;
  int get _safeChunkTokens => _chunkConfig.safeChunkTokens;
  int get _chunkCharacterSize => math.max(_charactersPerToken, _safeChunkTokens * _charactersPerToken);
  int get _chunkOverlapCharacters => math.max(0, _chunkOverlapTokens * _charactersPerToken);

  EnhancedSummaryService(this._baseSummaryService, SharedPreferences prefs)
      : _chunkConfig = ChunkingConfig.resolve(_baseSummaryService),
        _promptConfigService = PromptConfigService(prefs);

  String get serviceName => _baseSummaryService.serviceName;

  static int _computeChunkIndex(int characterIndex, int chunkCharacterSize) {
    if (characterIndex <= 0) {
      return 0;
    }
    final safeSize = math.max(1, chunkCharacterSize);
    final normalizedIndex = math.max(0, characterIndex - 1);
    return normalizedIndex ~/ safeSize;
  }

  int estimateChunkIndexForCharacter(int characterIndex) {
    return _computeChunkIndex(characterIndex, _chunkCharacterSize);
  }

  static int computeChunkIndexForCharacterStatic(int characterIndex) {
    const defaultSafeChunkTokens = 2550;
    final defaultChunkCharacters =
        math.max(1, defaultSafeChunkTokens * _charactersPerToken);
    return _computeChunkIndex(characterIndex, defaultChunkCharacters);
  }

  Future<String> runCustomPrompt(
    String prompt,
    String languageCode, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    return await _baseSummaryService.generateSummary(
      prompt,
      languageCode,
      bookId: bookId,
      onCacheHit: onCacheHit,
    );
  }

  /// Extract plain text from HTML content
  String _extractTextFromHtml(String htmlContent) {
    try {
      return HtmlTextExtractor.extract(htmlContent);
    } catch (e) {
      debugPrint('Error parsing HTML: $e');
      final fallback = htmlContent
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return normalizeWhitespace(fallback);
    }
  }

  /// Extract text from the book up to a specific character index.
  Future<List<ChapterText>> _extractTextUpToCharacterIndex(
    Book book,
    int targetCharacterIndex,
  ) async {
    final safeTarget = math.max(0, targetCharacterIndex);
    if (safeTarget == 0) {
      return const <ChapterText>[];
    }

    final epub = await _bookService.loadEpubBook(book.filePath);
    final parsedChapters = _parseChapters(epub);
    final orderedSections =
        parsedChapters.isNotEmpty ? parsedChapters : _fallbackSectionsFromContent(epub);

    if (orderedSections.isEmpty) {
      return const <ChapterText>[];
    }

    final segments = <ChapterText>[];
    var remaining = safeTarget;
    var segmentIndex = 0;
    final segmentLength = math.max(_chunkCharacterSize, 4000);

    for (final section in orderedSections) {
      if (remaining <= 0) {
        break;
      }

      final plainText = _extractTextFromHtml(section.htmlContent);
      if (plainText.isEmpty) {
        continue;
      }

      final takeLength = math.min(remaining, plainText.length);
      if (takeLength <= 0) {
        break;
      }

      final truncated = plainText.substring(0, takeLength);
      final isCompleteSection = takeLength == plainText.length;

      int offset = 0;
      while (offset < truncated.length) {
        final end = math.min(offset + segmentLength, truncated.length);
        segments.add(ChapterText(
          chapterIndex: segmentIndex++,
          title: section.title,
          text: truncated.substring(offset, end),
          isComplete: isCompleteSection && end == truncated.length,
        ));
        offset = end;
      }

      remaining -= takeLength;

      if (!isCompleteSection) {
        break;
      }
    }

    return segments;
  }

  List<Chapter> _fallbackSectionsFromContent(EpubBook epub) {
    final htmlFiles = epub.Content?.Html;
    if (htmlFiles == null || htmlFiles.isEmpty) {
      return const <Chapter>[];
    }

    final entries = htmlFiles.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final sections = <Chapter>[];

    for (var i = 0; i < entries.length; i++) {
      final file = entries[i].value;
      final content = file.Content ?? '';
      if (content.isEmpty) {
        continue;
      }
      // EpubTextContentFile no longer exposes Title; use a simple fallback.
      final title = 'Section ${i + 1}';
      sections.add(Chapter(
        index: i,
        title: title,
        htmlContent: content,
      ));
    }

    return sections;
  }

  /// Estimate token count (rough approximation: 1 token ≈ 4 characters)
  int _estimateTokenCount(String text) {
    return (text.length / 4).round();
  }

  String _hashText(String text) {
    final bytes = utf8.encode(text);
    return sha256.convert(bytes).toString();
  }

  List<_ChunkDefinition> _buildChunksFromText(String text) {
    if (text.isEmpty) {
      return <_ChunkDefinition>[];
    }

    final chunks = <_ChunkDefinition>[];
    final int chunkSize = _chunkCharacterSize;
    final int overlapSize = math.min(_chunkOverlapCharacters, chunkSize ~/ 2);

    int start = 0;
    while (start < text.length) {
      int end = math.min(start + chunkSize, text.length);

      if (end < text.length) {
        final searchWindowStart = math.max(start, end - 800);
        final window = text.substring(searchWindowStart, end);
        int breakOffset = window.lastIndexOf('\n\n');
        breakOffset = breakOffset >= 0 ? breakOffset : window.lastIndexOf('\n');
        breakOffset = breakOffset >= 0 ? breakOffset : window.lastIndexOf('. ');
        if (breakOffset >= 0) {
          final candidate = searchWindowStart + breakOffset + 1;
          if (candidate > start + 400) {
            end = candidate;
          }
        }
      }

      if (end <= start) {
        end = math.min(start + chunkSize, text.length);
      }

      final chunkText = text.substring(start, end);
      final hash = _hashText(chunkText);
      chunks.add(_ChunkDefinition(
        index: chunks.length,
        start: start,
        end: end,
        text: chunkText,
        hash: hash,
      ));

      if (end >= text.length) {
        break;
      }

      final nextStart = end - overlapSize;
      if (nextStart <= start) {
        start = end;
      } else {
        start = nextStart;
      }
    }

    return chunks;
  }

  Future<_PreparedTextData> _prepareTextData(
    Book book,
    int targetCharacterIndex,
    String language, {
    bool ensureChunkSummaries = true,
    double? readingProgressFraction,
    String? preparedEngineText,
  }) async {
    debugPrint('[SummaryDebug] _prepareTextData called: targetCharacterIndex=$targetCharacterIndex, ensureChunkSummaries=$ensureChunkSummaries, preparedEngineText length=${preparedEngineText?.length ?? 0}');
    // If an engine-prepared text stream is provided, prefer it to ensure
    // character indices match the pagination engine exactly.
    String fullText;
    if (preparedEngineText != null) {
      if (preparedEngineText.isEmpty) {
        debugPrint('[SummaryDebug] _prepareTextData: preparedEngineText is empty, returning empty');
        return const _PreparedTextData(fullText: '', chunks: <_ChunkDefinition>[]);
      }
      final safeEnd = math.min(targetCharacterIndex, preparedEngineText.length);
      if (safeEnd <= 0) {
        debugPrint('[SummaryDebug] _prepareTextData: safeEnd <= 0 ($safeEnd), returning empty');
        return const _PreparedTextData(fullText: '', chunks: <_ChunkDefinition>[]);
      }
      fullText = preparedEngineText.substring(0, safeEnd);
      debugPrint('[SummaryDebug] _prepareTextData: Using preparedEngineText, extracted ${fullText.length} characters');
    } else {
      debugPrint('[SummaryDebug] _prepareTextData: Extracting text from book...');
      final chapterTexts = await _extractTextUpToCharacterIndex(
        book,
        targetCharacterIndex,
      );
      debugPrint('[SummaryDebug] _prepareTextData: Extracted ${chapterTexts.length} chapters');

      if (chapterTexts.isEmpty) {
        debugPrint('[SummaryDebug] _prepareTextData: No chapter texts, returning empty');
        return const _PreparedTextData(
          fullText: '',
          chunks: <_ChunkDefinition>[],
        );
      }

      final buffer = StringBuffer();
      for (final chapterText in chapterTexts) {
        buffer.write(chapterText.text);
      }
      fullText = buffer.toString();
      debugPrint('[SummaryDebug] _prepareTextData: Built fullText from chapters, length=${fullText.length}');
    }

    // Debug: Log the full text captured up to the target (can be large)
    if (kDebugMode) {
      debugPrint('[SummaryDebug] FULL_TEXT_CAPTURED length=${fullText.length}');
      debugPrint(fullText);
      debugPrint('[SummaryDebug] END_FULL_TEXT_CAPTURED');
    }

    _logExtractionWindowDebug(
      book: book,
      targetCharacterIndex: targetCharacterIndex,
      fullText: fullText,
      chapterTexts: const <ChapterText>[],
      readingProgressFraction: readingProgressFraction,
    );

    debugPrint('[SummaryDebug] _prepareTextData: Building chunks from text...');
    final chunks = _buildChunksFromText(fullText);
    debugPrint('[SummaryDebug] _prepareTextData: Built ${chunks.length} chunks');

    if (ensureChunkSummaries && chunks.isNotEmpty) {
      debugPrint('[SummaryDebug] _prepareTextData: Ensuring chunk summaries for ${chunks.length} chunks...');
      await _ensureChunkSummaries(book, chunks, language);
      debugPrint('[SummaryDebug] _prepareTextData: Chunk summaries ensured');
    } else {
      debugPrint('[SummaryDebug] _prepareTextData: Skipping chunk summary generation (ensureChunkSummaries=$ensureChunkSummaries, chunks.isEmpty=${chunks.isEmpty})');
    }

    debugPrint('[SummaryDebug] _prepareTextData: Returning prepared data');
    return _PreparedTextData(
      fullText: fullText,
      chunks: chunks,
    );
  }

  Future<void> _ensureChunkSummaries(
    Book book,
    List<_ChunkDefinition> chunks,
    String language,
  ) async {
    debugPrint('[SummaryDebug] _ensureChunkSummaries: Starting for ${chunks.length} chunks');
    for (final chunk in chunks) {
      debugPrint('[SummaryDebug] _ensureChunkSummaries: Processing chunk ${chunk.index} (${chunk.start}-${chunk.end})');
      final existing = await _dbService.getSummaryChunk(book.id, chunk.index);

      if (existing != null && existing.contentHash == chunk.hash) {
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Chunk ${chunk.index} already exists with matching hash');
        if (existing.startCharacterIndex != chunk.start ||
            existing.endCharacterIndex != chunk.end) {
          debugPrint('[SummaryDebug] _ensureChunkSummaries: Updating character indices for chunk ${chunk.index}');
          final updatedChunk = BookSummaryChunk(
            bookId: existing.bookId,
            chunkIndex: existing.chunkIndex,
            chunkType: ChunkType.fixedBlock,
            summaryText: existing.summaryText,
            tokenCount: existing.tokenCount ?? _estimateTokenCount(chunk.text),
            createdAt: existing.createdAt,
            eventsJson: existing.eventsJson,
            characterNotesJson: existing.characterNotesJson,
            startCharacterIndex: chunk.start,
            endCharacterIndex: chunk.end,
            contentHash: existing.contentHash,
            events: existing.events,
            characterNotes: existing.characterNotes,
          );
          await _dbService.saveSummaryChunk(updatedChunk);
        }
        continue;
      }

      final chunkText = chunk.text.trim();
      if (chunkText.isEmpty) {
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Chunk ${chunk.index} text is empty, skipping');
        continue;
      }

      try {
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Generating summary for chunk ${chunk.index} (text length: ${chunkText.length})...');
        final summary = await _generateChunkSummary(
          chunkText,
          null,
          language,
          chunkIndex: chunk.index,
          startIndex: chunk.start,
          endIndex: chunk.end,
          debugContext: 'chunk_cache_generation',
          bookId: book.id,
          onCacheHit: null, // Don't show cache message for background chunk generation
        );
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Generated summary for chunk ${chunk.index}, length: ${summary.length}');

        if (summary.trim().isEmpty ||
            summary.contains('[Unable to generate') ||
            summary.contains('[Summary generation failed') ||
            summary.contains('Exception:')) {
          debugPrint('Invalid summary generated for chunk ${chunk.index}, skipping cache');
          continue;
        }

        final summaryChunk = BookSummaryChunk(
          bookId: book.id,
          chunkIndex: chunk.index,
          chunkType: ChunkType.fixedBlock,
          summaryText: summary,
          tokenCount: _estimateTokenCount(chunk.text),
          createdAt: DateTime.now(),
          startCharacterIndex: chunk.start,
          endCharacterIndex: chunk.end,
          contentHash: chunk.hash,
        );

        await _dbService.saveSummaryChunk(summaryChunk);
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Saved chunk ${chunk.index} summary');
      } catch (e, stackTrace) {
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Error generating summary for chunk ${chunk.index}: $e');
        debugPrint('[SummaryDebug] _ensureChunkSummaries: Stack trace: $stackTrace');
      }
    }
    debugPrint('[SummaryDebug] _ensureChunkSummaries: Completed for all chunks');
  }

  /// Split a large paragraph into smaller pieces by sentences
  List<String> _splitLargeParagraph(
    String paragraph,
    int maxTokens,
    int overlapTokens,
  ) {
    final chunks = <String>[];
    final sentences = paragraph.split(RegExp(r'[.!?]+\s+'));
    String currentChunk = '';
    int currentTokens = 0;
    
    for (final sentence in sentences) {
      final trimmed = sentence.trim();
      if (trimmed.isEmpty) continue;
      
      final sentenceTokens = _estimateTokenCount(trimmed);
      
      if (currentTokens + sentenceTokens > maxTokens && currentChunk.isNotEmpty) {
        chunks.add(currentChunk.trim());
        currentChunk = trimmed;
        currentTokens = sentenceTokens;
      } else {
        currentChunk = currentChunk.isEmpty ? trimmed : '$currentChunk. $trimmed';
        currentTokens += sentenceTokens;
      }
    }
    
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.trim());
    }
    
    return chunks.isNotEmpty ? chunks : [paragraph];
  }

  /// Extract overlap text from the tail of a chunk for continuity
  String _extractOverlapTail(String chunk, int overlapTokens) {
    if (overlapTokens <= 0) return '';
    
    final words = chunk.split(RegExp(r'\s+'));
    final overlapWordCount = (overlapTokens * 0.75).round();
    
    if (words.length <= overlapWordCount) {
      return chunk;
    }
    
    return words.skip(words.length - overlapWordCount).join(' ');
  }

  /// Split text into chunks if it's too large
  List<String> _splitTextIntoChunks(
    String text,
    int maxTokens, {
    int overlapTokens = 60,
  }) {
    final chunks = <String>[];
    final tokenCount = _estimateTokenCount(text);

    if (tokenCount <= maxTokens) {
      return [text];
    }

    // Split by paragraphs first
    final paragraphs = text.split(RegExp(r'\n\n+'));
    String currentChunk = '';
    int currentTokenCount = 0;

    for (final paragraph in paragraphs) {
      final trimmedParagraph = paragraph.trim();
      if (trimmedParagraph.isEmpty) {
        continue;
      }

      final paraTokenCount = _estimateTokenCount(trimmedParagraph);

      if (paraTokenCount > maxTokens) {
        // Split the large paragraph into smaller pieces
        final subChunks = _splitLargeParagraph(
          trimmedParagraph,
          maxTokens,
          overlapTokens,
        );
        for (final subChunk in subChunks) {
          if (currentTokenCount + _estimateTokenCount(subChunk) > maxTokens &&
              currentChunk.isNotEmpty) {
            chunks.add(currentChunk.trim());
            final overlapText = _extractOverlapTail(
              currentChunk,
              overlapTokens,
            );
            currentChunk = overlapText.isNotEmpty
                ? '$overlapText\n\n$subChunk\n\n'
                : '$subChunk\n\n';
            currentTokenCount = _estimateTokenCount(currentChunk);
          } else {
            currentChunk += '$subChunk\n\n';
            currentTokenCount = _estimateTokenCount(currentChunk);
          }
        }
        continue;
      }

      if (currentTokenCount + paraTokenCount > maxTokens &&
          currentChunk.isNotEmpty) {
        chunks.add(currentChunk.trim());
        final overlapText = _extractOverlapTail(
          currentChunk,
          overlapTokens,
        );
        currentChunk = overlapText.isNotEmpty
            ? '$overlapText\n\n$trimmedParagraph\n\n'
            : '$trimmedParagraph\n\n';
        currentTokenCount = _estimateTokenCount(currentChunk);
      } else {
        currentChunk += '$trimmedParagraph\n\n';
        currentTokenCount += paraTokenCount;
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.trim());
    }

    return chunks;
  }

  double? _progressFractionToPercent(double? fraction) {
    if (fraction == null || fraction.isNaN || fraction.isInfinite) {
      return null;
    }
    final clamped = (fraction * 100).clamp(0.0, 100.0);
    return clamped.toDouble();
  }

  double? _resolveProgressFraction(ReadingProgress progress) {
    final stored = progress.progress;
    if (stored != null && !stored.isNaN && !stored.isInfinite) {
      return stored.clamp(0.0, 1.0);
    }

    final totalChars = progress.totalCharacters;
    final current = progress.currentCharacterIndex;
    if (totalChars != null && totalChars > 0 && current != null) {
      final clampedCurrent = current.clamp(0, math.max(0, totalChars - 1));
      return (clampedCurrent + 1) / totalChars;
    }

    return null;
  }

  String _extractLastWords(String text, int wordCount) {
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) {
      return '';
    }
    final words = trimmed.split(RegExp(r'\s+'));
    final start = math.max(0, words.length - wordCount);
    return words.sublist(start).join(' ');
  }

  void _logExtractionWindowDebug({
    required Book book,
    required int targetCharacterIndex,
    required String fullText,
    required List<ChapterText> chapterTexts,
    double? readingProgressFraction,
  }) {
    if (!kDebugMode) {
      return;
    }

    final percent = _progressFractionToPercent(readingProgressFraction);
    final lastChapter = chapterTexts.isNotEmpty ? chapterTexts.last : null;
    final trailingWords = _extractLastWords(fullText, 10);
    final progressText = percent != null
        ? '${percent.toStringAsFixed(2)}%'
        : 'unknown';
    final lastChapterInfo = lastChapter != null
        ? 'last chapter "${lastChapter.title}" (complete: ${lastChapter.isComplete})'
        : 'no chapter data';

    debugPrint('[SummaryDebug] Extracted ${fullText.length} chars '
        'for "${book.title}" up to index $targetCharacterIndex '
        '(reading progress: $progressText, $lastChapterInfo).');
    if (trailingWords.isNotEmpty) {
      debugPrint('[SummaryDebug] Trailing context before cutoff: "$trailingWords"');
    }
  }

  void _logChunkSummaryDebug({
    required String stage,
    required String text,
    int? chunkIndex,
    int? startIndex,
    int? endIndex,
    double? readingProgressPercent,
  }) {
    if (!kDebugMode) {
      return;
    }

    final preview = text.length > 240 ? '${text.substring(0, 240)}…' : text;
    final trailingWords = _extractLastWords(text, 10);
    final progressText = readingProgressPercent != null
        ? '${readingProgressPercent.toStringAsFixed(2)}%'
        : 'unknown';
    debugPrint('[SummaryDebug][$stage] chunk=${chunkIndex ?? '-'} '
        'range=${startIndex ?? '-'}-${endIndex ?? '-'} '
        'length=${text.length} progress=$progressText');
    debugPrint('[SummaryDebug][$stage] preview="$preview"');
    if (trailingWords.isNotEmpty) {
      debugPrint('[SummaryDebug][$stage] trailing="$trailingWords"');
    }
  }

  /// Parse chapters from EPUB book
  List<Chapter> _parseChapters(EpubBook epub) {
    final chapters = <Chapter>[];
    try {
      final epubChapters = epub.Chapters;
      if (epubChapters == null || epubChapters.isEmpty) {
        return chapters;
      }
      
      for (int i = 0; i < epubChapters.length; i++) {
        try {
          final epubChapter = epubChapters[i];
          final title = epubChapter.Title?.isNotEmpty == true
              ? epubChapter.Title!
              : 'Chapter ${i + 1}';
          final htmlContent = epubChapter.HtmlContent ?? '';
          
          if (htmlContent.isNotEmpty) {
            chapters.add(Chapter(
              index: i,
              title: title,
              htmlContent: htmlContent,
            ));
          }
        } catch (e) {
          debugPrint('Error parsing chapter $i: $e');
        }
      }
    } catch (e) {
      debugPrint('Error parsing chapters: $e');
    }
    
    return chapters.isEmpty ? [] : chapters;
  }

  /// Get language from app locale (helper method, will be called from context)
  String _getLanguage(String languageCode) {
    return languageCode; // 'fr' or 'en'
  }

  /// Generate summary for a single chunk using the base summary service
  Future<String> _generateChunkSummary(
    String text,
    String? chunkTitle,
    String language, {
    int? chunkIndex,
    int? startIndex,
    int? endIndex,
    String? debugContext,
    double? readingProgressPercent,
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    try {
      // Limit text size to prevent crashes in native libraries
      // The text should already be plain text, but extract just in case
      String plainText = text;
      if (text.contains('<')) {
        // If it looks like HTML, extract plain text
        plainText = _extractTextFromHtml(text);
      }
      
      // Use extremely conservative limits to avoid crashes
      // The local summary service will further limit this on macOS (to ~200 chars)
      // So we pre-limit here to be safe
      final maxTextLength = 500; // Conservative pre-limit
      final safeText = plainText.length > maxTextLength
          ? '${plainText.substring(0, maxTextLength)}...'
          : plainText;
      
      // Build prompt with explicit instructions to avoid prompt leakage
      final prompt = _buildChunkSummaryPrompt(safeText, chunkTitle, language);

      // Use the base summary service with error handling
      _logChunkSummaryDebug(
        stage: debugContext ?? 'chunk_summary',
        text: safeText,
        chunkIndex: chunkIndex,
        startIndex: startIndex,
        endIndex: endIndex,
        readingProgressPercent: readingProgressPercent,
      );
      final summary = await _baseSummaryService.generateSummary(
        prompt,
        language,
        bookId: bookId,
        onCacheHit: onCacheHit,
      );
      
      // Validate the summary is not empty or just error text
      if (summary.trim().isEmpty || 
          summary.contains('[Unable to generate') ||
          summary.contains('Exception:')) {
        debugPrint('Error generating chunk summary: Invalid summary returned');
        throw Exception('Invalid summary generated for chunk: ${chunkTitle ?? "unknown"}');
      }
      
      return summary;
    } catch (e) {
      debugPrint('Error generating chunk summary: $e');
      // Re-throw the error so it can be handled at a higher level
      // Don't return error messages as summaries - they will be filtered out
      rethrow;
    }
  }

  /// Format timestamp for display
  String _formatTimestamp(DateTime timestamp, String languageCode) {
    try {
      if (languageCode == 'fr') {
        // French format: "4 nov., 14:05"
        final dateFormat = DateFormat('d MMM', 'fr');
        final timeFormat = DateFormat('HH:mm', 'fr');
        final dateStr = dateFormat.format(timestamp);
        final timeStr = timeFormat.format(timestamp);
        return '$dateStr, $timeStr';
      } else {
        // English format: "Nov. 4th, 2:05pm"
        final dateFormat = DateFormat('MMM d', 'en');
        final timeFormat = DateFormat('h:mma', 'en');
        
        final dateStr = dateFormat.format(timestamp);
        final timeStr = timeFormat.format(timestamp).toLowerCase();
        
        // Add ordinal suffix for English (1st, 2nd, 3rd, 4th, etc.)
        final day = timestamp.day;
        String suffix;
        if (day >= 11 && day <= 13) {
          suffix = 'th';
        } else {
          switch (day % 10) {
            case 1:
              suffix = 'st';
              break;
            case 2:
              suffix = 'nd';
              break;
            case 3:
              suffix = 'rd';
              break;
            default:
              suffix = 'th';
          }
        }
        
        // Extract just the day number and add suffix
        final dayPattern = RegExp(r'\d+');
        final dayMatch = dayPattern.firstMatch(dateStr);
        if (dayMatch != null) {
          final dayNumber = dayMatch.group(0)!;
          final monthStr = dateStr.replaceFirst(dayNumber, '').trim();
          return '$monthStr $dayNumber$suffix, $timeStr';
        }
        
        return '$dateStr, $timeStr';
      }
    } catch (e) {
      debugPrint('Error formatting timestamp: $e');
      return DateFormat('MMM d, h:mma').format(timestamp).toLowerCase();
    }
  }

  /// Generate a general summary with structured event extraction
  /// This creates a unified narrative covering all important events
  Future<GeneralSummaryPayload> _generateGeneralSummary(
    List<BookSummaryChunk> chunks,
    String bookTitle,
    String language, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    if (chunks.isEmpty) {
      return GeneralSummaryPayload(narrative: 'No content available.');
    }

    // Collect all events from chunks (if already extracted)
    final allEvents = <SummaryEvent>[];
    for (final chunk in chunks) {
      final events = chunk.events;
      if (events != null && events.isNotEmpty) {
        allEvents.addAll(events);
      }
    }

    // Build narrative from chunk summaries
    final summaryTexts = chunks.map((c) => c.summaryText).toList();
    
    // For large books, create a hierarchical summary
    String narrative;
    if (summaryTexts.length > _maxChunksPerBatch) {
      // Process in batches to avoid overwhelming the LLM
      final batches = <List<String>>[];
      for (int i = 0; i < summaryTexts.length; i += _maxChunksPerBatch) {
        final end = math.min(i + _maxChunksPerBatch, summaryTexts.length);
        batches.add(summaryTexts.sublist(i, end));
      }

      // Summarize each batch
      final batchSummaries = <String>[];
      for (int i = 0; i < batches.length; i++) {
        final batchSummary = await _summarizeBatch(
          batches[i],
          '$bookTitle - Part ${i + 1}',
          language,
          bookId: bookId,
          onCacheHit: onCacheHit,
        );
        batchSummaries.add(batchSummary);
      }

      // Combine batch summaries into final narrative
      narrative = await _synthesizeNarrative(
        batchSummaries,
        bookTitle,
        language,
        bookId: bookId,
        onCacheHit: onCacheHit,
      );
    } else {
      // Small enough to process directly
      narrative = await _synthesizeNarrative(
        summaryTexts,
        bookTitle,
        language,
        bookId: bookId,
        onCacheHit: onCacheHit,
      );
    }

    return GeneralSummaryPayload(
      narrative: narrative,
      keyEvents: allEvents,
    );
  }

  /// Remove duplicate summaries from a list
  List<String> _removeDuplicateSummaries(List<String> summaries) {
    final unique = <String>[];
    final seen = <String>{};
    
    for (final summary in summaries) {
      final normalized = summary.trim().toLowerCase();
      // Skip if we've seen this exact text before
      if (seen.contains(normalized)) {
        debugPrint('Skipping duplicate summary: ${summary.substring(0, math.min(50, summary.length))}...');
        continue;
      }
      
      // Skip if this summary is very similar to an existing one (80% overlap)
      bool isDuplicate = false;
      for (final existing in seen) {
        if (_calculateSimilarity(normalized, existing) > 0.8) {
          debugPrint('Skipping similar summary (similarity > 80%)');
          isDuplicate = true;
          break;
        }
      }
      
      if (!isDuplicate) {
        unique.add(summary);
        seen.add(normalized);
      }
    }
    
    return unique;
  }
  
  /// Calculate similarity between two strings (simple word overlap)
  double _calculateSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    
    final wordsA = a.split(RegExp(r'\s+')).toSet();
    final wordsB = b.split(RegExp(r'\s+')).toSet();
    
    if (wordsA.isEmpty || wordsB.isEmpty) return 0.0;
    
    final intersection = wordsA.intersection(wordsB).length;
    final union = wordsA.union(wordsB).length;
    
    return intersection / union;
  }

  /// Summarize a batch of chapter summaries into a flowing narrative
  Future<String> _summarizeBatch(
    List<String> chapterSummaries,
    String sectionTitle,
    String language, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    // Remove duplicates before combining
    final uniqueSummaries = _removeDuplicateSummaries(chapterSummaries);
    if (uniqueSummaries.isEmpty) {
      debugPrint('No unique summaries to combine in batch');
      return '';
    }
    
    final combined = uniqueSummaries.join(' ');
    final prompt = _buildBatchSummaryPrompt(combined, language);

    try {
      return await _baseSummaryService.generateSummary(
        prompt,
        language,
        bookId: bookId,
        onCacheHit: onCacheHit,
      );
    } catch (e) {
      debugPrint('Error summarizing batch: $e');
      return combined; // Fallback to concatenation
    }
  }

  /// Build a prompt for batch summarization using custom prompts
  String _buildBatchSummaryPrompt(String combinedSummaries, String language) {
    final promptTemplate = _promptConfigService.getBatchSummaryPrompt(language);
    return _promptConfigService.formatPrompt(promptTemplate, text: combinedSummaries);
  }

  /// Synthesize a final narrative from summaries
  Future<String> _synthesizeNarrative(
    List<String> summaries,
    String bookTitle,
    String language, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    // Remove duplicates before combining
    final uniqueSummaries = _removeDuplicateSummaries(summaries);
    if (uniqueSummaries.isEmpty) {
      debugPrint('No unique summaries to synthesize');
      return language == 'fr'
          ? 'Aucun résumé disponible pour $bookTitle.'
          : 'No summary available for $bookTitle.';
    }
    
    // Combine all summaries into one text without chapter markers
    final combined = uniqueSummaries.join('\n\n');
    
    final prompt = _buildNarrativeSynthesisPrompt(combined, bookTitle, language);

    try {
      final narrative = await _baseSummaryService.generateSummary(
        prompt,
        language,
        bookId: bookId,
        onCacheHit: onCacheHit,
      );
      // Return the synthesized narrative directly
      return narrative;
    } catch (e) {
      debugPrint('Error synthesizing narrative: $e');
      // Even in fallback, create a simple combined text without chapter headers
      final fallbackText = language == 'fr'
          ? 'Résumé de $bookTitle:\n\n$combined'
          : 'Summary of $bookTitle:\n\n$combined';
      return fallbackText;
    }
  }

  /// Build a prompt for narrative synthesis using custom prompts
  String _buildNarrativeSynthesisPrompt(String combinedSummaries, String bookTitle, String language) {
    final promptTemplate = _promptConfigService.getNarrativeSynthesisPrompt(language);
    return _promptConfigService.formatPrompt(
      promptTemplate,
      text: combinedSummaries,
    );
  }

  /// Format a general summary payload for display
  String _formatGeneralSummary(GeneralSummaryPayload payload) {
    final buffer = StringBuffer();
    buffer.writeln(payload.narrative);
    
    if (payload.keyEvents.isNotEmpty) {
      buffer.writeln('\n\n## Key Events');
      for (final event in payload.keyEvents) {
        buffer.writeln('\n### ${event.title}');
        buffer.writeln(event.description);
        if (event.involvedCharacters.isNotEmpty) {
          buffer.writeln('*Characters: ${event.involvedCharacters.join(', ')}*');
        }
      }
    }
    
    return buffer.toString();
  }

  /// Get or generate summary up to the current reading position (from beginning)
  /// Uses currentCharacterIndex to extract text exactly up to the reading position
  Future<String> getSummaryUpToPosition(
    Book book,
    ReadingProgress progress,
    String languageCode, {
    String? preparedEngineText,
    VoidCallback? onCacheHit,
  }) async {
    try {
      debugPrint('[SummaryDebug] getSummaryUpToPosition called for book ${book.id}');
      // Summaries now rely solely on exact character offsets; when none are
      // available we consider the user to be at the very beginning.
      final currentCharacterIndex = math.max(0, progress.currentCharacterIndex ?? 0);
      final language = _getLanguage(languageCode);

      debugPrint('[SummaryDebug] currentCharacterIndex: $currentCharacterIndex, language: $language');

      if (currentCharacterIndex <= 0) {
        debugPrint('[SummaryDebug] Early return: No content read yet');
        return 'No content read yet.';
      }

      debugPrint('[SummaryDebug] Calling _prepareTextData...');
      final prepared = await _prepareTextData(
        book,
        currentCharacterIndex,
        language,
        ensureChunkSummaries: true,
        readingProgressFraction: _resolveProgressFraction(progress),
        preparedEngineText: preparedEngineText,
      );
      debugPrint('[SummaryDebug] _prepareTextData completed. fullText length: ${prepared.fullText.length}, chunks: ${prepared.chunks.length}');

      if (prepared.fullText.isEmpty) {
        debugPrint('[SummaryDebug] Error: No content found in book');
        throw Exception('No content found in book');
      }

      debugPrint('[SummaryDebug] Getting summary cache...');
      final cache = await _dbService.getSummaryCache(book.id);
      final cachedCharacterIndex = cache?.lastProcessedCharacterIndex ?? -1;
      debugPrint('[SummaryDebug] Cache found: ${cache != null}, cachedCharacterIndex: $cachedCharacterIndex');

      if (cache != null &&
          cachedCharacterIndex == currentCharacterIndex &&
          cache.cumulativeSummary.isNotEmpty &&
          // If we are using engine-aligned text, do not short-circuit to avoid stale summaries
          preparedEngineText == null) {
        debugPrint('[SummaryDebug] Returning cached summary');
        return cache.cumulativeSummary;
      }

      final maxChunkIndex = prepared.chunks.isNotEmpty
          ? prepared.chunks.last.index
          : -1;
      debugPrint('[SummaryDebug] Getting chunk summaries, maxChunkIndex: $maxChunkIndex');
      final allChunkSummaries = await _dbService.getSummaryChunks(
        book.id,
        maxChunkIndex,
      );
      debugPrint('[SummaryDebug] Found ${allChunkSummaries.length} chunk summaries');
      
      // Filter out invalid cached summaries
      final validChunkSummaries = allChunkSummaries.where((chunk) {
        final summary = chunk.summaryText;
        if (summary.contains('[Summary generation failed') ||
            summary.contains('[Unable to generate') ||
            summary.contains('Exception:') ||
            summary.contains('resume for a job') ||
            summary.contains('concise and clear resume') ||
            summary.trim().endsWith('?') ||
            summary.length < 50) {
          debugPrint('[SummaryDebug] Filtering out invalid cached summary for chunk ${chunk.chunkIndex}');
          return false;
        }
        return true;
      }).toList();
      
      debugPrint('[SummaryDebug] Valid chunk summaries: ${validChunkSummaries.length}');
      if (validChunkSummaries.isEmpty) {
        debugPrint('[SummaryDebug] Error: No valid summaries available');
        throw Exception('No valid summaries available. Please ensure you have read some content and that chunk summaries have been generated.');
      }

      debugPrint('[SummaryDebug] Generating general summary...');
      // Generate hierarchical summary with structured data
      final generalSummary = await _generateGeneralSummary(
        validChunkSummaries,
        book.title,
        language,
        bookId: book.id,
        onCacheHit: onCacheHit,
      );
      debugPrint('[SummaryDebug] General summary generated');

      // Format for display
      debugPrint('[SummaryDebug] Formatting general summary...');
      final narrative = _formatGeneralSummary(generalSummary);

      // Update cache with structured and text summary
      debugPrint('[SummaryDebug] Saving summary cache...');
      final updatedCache = (cache ?? BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: maxChunkIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
      )).copyWith(
        lastProcessedChunkIndex: maxChunkIndex,
        lastProcessedCharacterIndex: currentCharacterIndex,
        cumulativeSummary: narrative,
        generalSummaryJson: generalSummary.toJsonString(),
        generalSummaryUpdatedAt: DateTime.now(),
        lastUpdated: DateTime.now(),
        generalSummary: generalSummary,
      );
      await _dbService.saveSummaryCache(updatedCache);
      debugPrint('[SummaryDebug] Summary generation completed successfully');

      return narrative;
    } catch (e, stackTrace) {
      debugPrint('[SummaryDebug] Error generating summary up to position: $e');
      debugPrint('[SummaryDebug] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Get summary since last reading session
  /// Uses currentCharacterIndex to extract text exactly up to the reading position
  Future<String> getSummarySinceLastTime(
    Book book,
    ReadingProgress progress,
    String languageCode, {
    String? preparedEngineText,
    VoidCallback? onCacheHit,
  }) async {
    try {
      final language = _getLanguage(languageCode);
      final cache = await _dbService.getSummaryCache(book.id);
      // Use the same exact character window as the "from the beginning" summary
      // to avoid drift between different summary modes.
      final currentCharacterIndex = math.max(0, progress.currentCharacterIndex ?? 0);

      if (currentCharacterIndex <= 0) {
        return language == 'fr'
            ? 'Aucune lecture détectée.'
            : 'No reading progress detected.';
      }

      final prepared = await _prepareTextData(
        book,
        currentCharacterIndex,
        language,
        readingProgressFraction: _resolveProgressFraction(progress),
        preparedEngineText: preparedEngineText,
      );

      // Parse reading interruptions from cache
      List<Map<String, dynamic>> interruptions = [];
      if (cache?.readingInterruptionsJson != null) {
        try {
          final decoded = jsonDecode(cache!.readingInterruptionsJson!) as List;
          interruptions = decoded.cast<Map<String, dynamic>>();
        } catch (e) {
          debugPrint('Error parsing reading interruptions: $e');
          interruptions = [];
        }
      }

      // Find the most recent interruption that's different from current position
      // Go through interruptions in reverse order (most recent first)
      int? sessionStartCharacterIndex;
      DateTime? sessionStartTimestamp;
      
      for (int i = interruptions.length - 1; i >= 0; i--) {
        final interruption = interruptions[i];
        final interruptCharIndex = interruption['characterIndex'] as int?;
        final interruptProgress = (interruption['progress'] as num?)?.toDouble();
        final estimatedCharIndex = interruptCharIndex ??
            ((interruptProgress != null && prepared.fullText.isNotEmpty)
                ? (interruptProgress.clamp(0.0, 1.0) * prepared.fullText.length)
                    .floor()
                : null);

        if (estimatedCharIndex != null &&
            estimatedCharIndex < currentCharacterIndex) {
          // Found an interruption before current position - this is our session start
          sessionStartCharacterIndex = estimatedCharIndex;
          final timestampStr = interruption['timestamp'] as String?;
          if (timestampStr != null) {
            try {
              sessionStartTimestamp = DateTime.parse(timestampStr);
            } catch (e) {
              debugPrint('Error parsing interruption timestamp: $e');
            }
          }
          break;
        }
      }

      // If no interruption found, use 0 as start
      final effectiveSessionStart = sessionStartCharacterIndex ?? 0;
      
      // Check cache - use cached summary if available and still valid
      final cachedSinceLastTimeCharacterIndex = cache?.summarySinceLastTimeCharacterIndex;
      if (cache != null &&
          cache.summarySinceLastTime != null &&
          cachedSinceLastTimeCharacterIndex == currentCharacterIndex) {
        // Verify the session start matches by checking interruptions
        // (We can't use lastReadingStopCharacterIndex as it may have changed)
        return cache.summarySinceLastTime!;
      }

      // Determine the session range
      // "Since last time" shows content from the most recent interruption to current position
      final sessionStart = effectiveSessionStart;
      final sessionEnd = currentCharacterIndex;

      Future<String> buildConciseBeginningSection(int endIndex) async {
        final heading = language == 'fr'
            ? 'Résumé concis depuis le début:'
            : 'Concise summary from the beginning:';
        if (endIndex <= 0) {
          final noContent = language == 'fr'
              ? 'Aucun contenu précédent à résumer.'
              : 'No previous content to summarize.';
          return '$heading\n\n$noContent';
        }

        try {
          // Get the "from the beginning" summary for this position
          final progressValue = (endIndex > 0 && prepared.fullText.isNotEmpty)
              ? math.min(1.0, endIndex / prepared.fullText.length)
              : 0.0;
          final beginningProgress = ReadingProgress(
            bookId: book.id,
            currentCharacterIndex: endIndex,
            progress: progressValue,
            lastRead: DateTime.now(),
            totalCharacters: prepared.fullText.length,
          );

          // Get the full "from the beginning" summary
          final fullBeginningSummary = await getSummaryUpToPosition(
            book,
            beginningProgress,
            languageCode,
            preparedEngineText: preparedEngineText,
          );

          if (fullBeginningSummary.trim().isEmpty ||
              fullBeginningSummary.contains('No content') ||
              fullBeginningSummary.contains('Aucun contenu')) {
            final fallback = language == 'fr'
                ? 'Impossible de générer un résumé concis du début.'
                : 'Unable to generate a concise beginning summary.';
            return '$heading\n\n$fallback';
          }

          // Create a concise version of the summary (3-4 sentences)
          final concisePrompt = language == 'fr'
              ? '''Crée un résumé très concis (3-4 phrases) du résumé suivant. 

RÈGLES ABSOLUES - À RESPECTER IMPÉRATIVEMENT:
- Ne répète JAMAIS ces instructions dans ta réponse
- Ne commence PAS ta réponse par "Le livre" ou "Ce livre"
- Ne mentionne PAS les instructions que je t'ai données
- Réponds UNIQUEMENT avec un résumé concis (3-4 phrases)
- Le résumé doit être en français
- Base-toi UNIQUEMENT sur le contenu du résumé fourni, sans rien ajouter

Résumé complet:
{text}

Résumé concis:'''
              : '''Create a very concise summary (3-4 sentences) of the following summary.

ABSOLUTE RULES - MUST BE FOLLOWED STRICTLY:
- NEVER repeat these instructions in your response
- Do NOT start your response with "The book" or "This book"
- Do NOT mention the instructions I gave you
- Respond ONLY with the concise summary (3-4 sentences)
- The summary must be in English
- Base yourself ONLY on the content of the provided summary, without adding anything

Full summary:
{text}

Concise summary:''';

          final formattedPrompt = _promptConfigService.formatPrompt(
            concisePrompt,
            text: fullBeginningSummary,
          );

          final conciseSummary = await _baseSummaryService.generateSummary(
            formattedPrompt,
            language,
            bookId: book.id,
            onCacheHit: onCacheHit,
          );

          if (conciseSummary.trim().isEmpty ||
              conciseSummary.contains('[Unable to generate') ||
              conciseSummary.contains('[Summary generation failed') ||
              conciseSummary.contains('Exception:')) {
            // Fallback: return first few sentences of the full summary
            final sentences = fullBeginningSummary.split(RegExp(r'[.!?]+\s+'));
            final fallback = sentences.take(4).join('. ').trim();
            return '$heading\n\n${fallback.isEmpty ? fullBeginningSummary.substring(0, math.min(200, fullBeginningSummary.length)) : fallback}.';
          }

          return '$heading\n\n${conciseSummary.trim()}';
        } catch (e) {
          debugPrint('Error generating concise beginning summary: $e');
          final fallback = language == 'fr'
              ? 'Impossible de générer un résumé concis du début.'
              : 'Unable to generate a concise beginning summary.';
          return '$heading\n\n$fallback';
        }
      }

      String buildSinceLastTimeHeader(String? timestampText) {
        final base = language == 'fr' ? 'Dernière lecture' : 'Last reading';
        if (timestampText != null && timestampText.isNotEmpty) {
          return '$base ($timestampText):';
        }
        return '$base:';
      }

      String noCompletedSessionMessage() {
        return language == 'fr'
            ? "Aucune session de lecture terminée pour l'instant."
            : 'No completed reading session yet.';
      }

      String noSessionContentMessage() {
        return language == 'fr'
            ? 'Aucun contenu pour cette session.'
            : 'No content in this session.';
      }

      String noNewContentMessage() {
        return language == 'fr'
            ? 'Aucun nouveau contenu.'
            : 'No new content.';
      }

      // If no interruption found or session has no content
      if (sessionStart >= sessionEnd) {
        // No content in this session - show concise beginning summary
        final conciseBeginningSection =
            await buildConciseBeginningSection(sessionEnd);

        String timestampText = '';
        if (sessionStartTimestamp != null) {
          timestampText = _formatTimestamp(sessionStartTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noSessionContentMessage()}';
      }

      // Get concise summary of beginning (up to sessionStart) for context
      final conciseBeginningSection =
          await buildConciseBeginningSection(sessionStart);

      // Extract text for the session (from sessionStart to sessionEnd)
      String sessionText = '';
      final safeEndIndex = math.min(sessionEnd, prepared.fullText.length);
      final startIndex = math.min(sessionStart, safeEndIndex);
      if (safeEndIndex > startIndex) {
        sessionText = prepared.fullText.substring(startIndex, safeEndIndex);
      }

      if (sessionText.trim().isEmpty) {
        String timestampText = '';
        if (sessionStartTimestamp != null) {
          timestampText = _formatTimestamp(sessionStartTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noNewContentMessage()}';
      }

      // Generate summary of the session text
      final textChunks = _splitTextIntoChunks(sessionText, _safeChunkTokens);

      String combinedSummary = '';
      int sessionOffset = 0;
      for (final chunkText in textChunks) {
        try {
          final chunkStart = sessionStart + sessionOffset;
          final chunkEnd = chunkStart + chunkText.length;
          sessionOffset += chunkText.length;
          final summary = await _generateChunkSummary(
            chunkText,
            null,
            language,
            startIndex: chunkStart,
            endIndex: chunkEnd,
            debugContext: 'since_last_time_session',
            readingProgressPercent:
                _progressFractionToPercent(_resolveProgressFraction(progress)),
            bookId: book.id,
            onCacheHit: onCacheHit,
          );

          if (summary.trim().isNotEmpty &&
              !summary.contains('[Unable to generate') &&
              !summary.contains('[Summary generation failed') &&
              !summary.contains('Exception:')) {
            if (combinedSummary.isEmpty) {
              combinedSummary = summary;
            } else {
              combinedSummary = '$combinedSummary\n\n$summary';
            }
          }
        } catch (e) {
          debugPrint('Error processing session chunk: $e');
        }
      }

      if (combinedSummary.isEmpty) {
        String timestampText = '';
        if (sessionStartTimestamp != null) {
          timestampText = _formatTimestamp(sessionStartTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noNewContentMessage()}';
      }

      // Format timestamp for display
      String timestampText = '';
      if (sessionStartTimestamp != null) {
        timestampText = _formatTimestamp(sessionStartTimestamp, languageCode);
      }

      // Combine: concise beginning + "Since last time:" + session summary
      final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
      final fullSummary =
          '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n$combinedSummary';
      
      // Cache the generated summary
      final sessionCoverageIndex = estimateChunkIndexForCharacter(sessionEnd);
      final updatedCache = (cache ?? BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: sessionCoverageIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
      )).copyWith(
        summarySinceLastTime: fullSummary,
        summarySinceLastTimeChunkIndex: sessionCoverageIndex,
        summarySinceLastTimeCharacterIndex: currentCharacterIndex,
        lastReadingStopCharacterIndex: sessionStart, // Store session start for cache validation
      );
      await _dbService.saveSummaryCache(updatedCache);
      
      return fullSummary;
    } catch (e) {
      debugPrint('Error generating summary since last time: $e');
      rethrow;
    }
  }

  /// Generate characters summary
  Future<String> getCharactersSummary(
    Book book,
    ReadingProgress progress,
    String languageCode, {
    String? preparedEngineText,
    VoidCallback? onCacheHit,
  }) async {
    try {
      final currentCharacterIndex = math.max(0, progress.currentCharacterIndex ?? 0);
      final language = _getLanguage(languageCode);

      if (currentCharacterIndex <= 0) {
        return 'No content read yet.';
      }

      final prepared = await _prepareTextData(
        book,
        currentCharacterIndex,
        language,
        readingProgressFraction: _resolveProgressFraction(progress),
        preparedEngineText: preparedEngineText,
      );

      if (prepared.fullText.isEmpty) {
        throw Exception('No content found in book');
      }

      // Get or create cache
      var cache = await _dbService.getSummaryCache(book.id);

      // Load existing character profiles from cache
      CharacterProfilesPayload existingProfiles = cache?.characterProfilesPayload ??
          CharacterProfilesPayload(profiles: []);
      final existingCharacterNames = existingProfiles.profiles.map((p) => p.name.toLowerCase()).toSet();

      // Get last processed character index for characters
      final lastCharacterProcessedCharacterIndex = cache?.charactersSummaryCharacterIndex ?? -1;

      // Check if we have a cached summary that's up to date
      if (cache != null &&
          cache.charactersSummary != null &&
          lastCharacterProcessedCharacterIndex == currentCharacterIndex) {
        return cache.charactersSummary!;
      }

      final startIndex = math.min(
        math.max(0, lastCharacterProcessedCharacterIndex + 1),
        prepared.fullText.length,
      );
      final newText = prepared.fullText.substring(startIndex);

      if (newText.trim().isNotEmpty) {
        final characterChunks = _splitTextIntoChunks(
          newText,
          _safeChunkTokens,
          overlapTokens: 0,
        );

        for (final chunkText in characterChunks) {
          if (chunkText.trim().isEmpty) {
            continue;
          }

          try {
            // Extract character information from this text
            final chunkNotes = await _extractCharactersFromText(
              chunkText,
              null,
              language,
              existingCharacterNames,
              bookId: book.id,
              onCacheHit: onCacheHit,
            );

            // Update character profiles with new information
            existingProfiles = _mergeCharacterProfiles(
              existingProfiles,
              chunkNotes,
              null,
            );

            // Update existing character names set
            for (final note in chunkNotes) {
              existingCharacterNames.add(note.name.toLowerCase());
            }
          } catch (e) {
            debugPrint('Error processing character chunk: $e');
          }
        }
      }

      // Generate final character profiles using structured data
      final charactersSummary = await _generateCharacterProfiles(
        existingProfiles,
        book.title,
        language,
      );

      // Cache the structured character profiles
      final characterChunkIndex = estimateChunkIndexForCharacter(currentCharacterIndex);
      final updatedCache = (cache ?? BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: characterChunkIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
      )).copyWith(
        characterProfilesJson: existingProfiles.toJsonString(),
        characterProfilesUpdatedAt: DateTime.now(),
        charactersSummary: charactersSummary,
        charactersSummaryChunkIndex: characterChunkIndex,
        charactersSummaryCharacterIndex: currentCharacterIndex,
      );
      
      await _dbService.saveSummaryCache(updatedCache);

      return charactersSummary;
    } catch (e) {
      debugPrint('Error generating characters summary: $e');
      rethrow;
    }
  }

  /// Extract character information from a text chunk
  /// Returns a list of character notes found in the text
  /// Processes characters from the text and extracts info for each one
  Future<List<ChunkCharacterNote>> _extractCharactersFromText(
    String text,
    String? chapterTitle,
    String language,
    Set<String> existingCharacterNames, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    try {
      // Limit text size based on service capabilities
      final maxLength = _chunkConfig.safeChunkTokens * 4; // Rough char estimate
      final safeText = text.length > maxLength 
          ? '${text.substring(0, maxLength)}...'
          : text;

      // Build prompt with explicit instructions to avoid prompt leakage
      final prompt = _buildCharacterExtractionPrompt(safeText, language);

      try {
        final response = await _baseSummaryService.generateSummary(
          prompt,
          language,
          bookId: bookId,
          onCacheHit: onCacheHit,
        );
        
        // Parse the response to extract character notes
        return _parseCharacterNotesFromStructuredResponse(response);
      } catch (e) {
        debugPrint('Error extracting characters from text: $e');
        return [];
      }
    } catch (e) {
      debugPrint('Error in _extractCharactersFromText: $e');
      return [];
    }
  }

  /// Build a prompt for character extraction using custom prompts
  String _buildCharacterExtractionPrompt(String text, String language) {
    final promptTemplate = _promptConfigService.getCharacterExtractionPrompt(language);
    return _promptConfigService.formatPrompt(promptTemplate, text: text);
  }

  /// Parse structured character notes from LLM response
  /// Expects format: **Character Name**\nSummary: ...\nActions: ...\nRelations: ...
  List<ChunkCharacterNote> _parseCharacterNotesFromStructuredResponse(String response) {
    final notes = <ChunkCharacterNote>[];
    
    // Split response by character blocks (identified by **Name** pattern)
    final lines = response.split('\n');
    
    String? currentCharacterName;
    String? currentSummary = '';
    final currentActions = <String>[];
    final currentRelationships = <String, String>{};
    String? currentSection;
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      
      final lower = line.toLowerCase();
      
      // Skip prompt-like lines
      if (lower.contains('présente chaque') ||
          lower.contains('present each') ||
          lower.contains('ne répète pas') ||
          lower.contains('do not repeat') ||
          lower.contains('instruction') ||
          lower.contains('format exact') ||
          lower.contains('exact format')) {
        continue;
      }
      
      // Detect character name (marked with **)
      if (line.startsWith('**') && line.endsWith('**')) {
        // Save previous character if any
        if (currentCharacterName != null && currentSummary != null && currentSummary.isNotEmpty) {
          notes.add(ChunkCharacterNote(
            name: currentCharacterName,
            summary: currentSummary.trim(),
            notableActions: List.from(currentActions),
            relationships: Map.from(currentRelationships),
          ));
        }
        
        // Start new character
        currentCharacterName = line.replaceAll('**', '').trim();
        currentSummary = '';
        currentActions.clear();
        currentRelationships.clear();
        currentSection = null;
        continue;
      }
      
      // Detect sections
      if (lower.startsWith('résumé:') || lower.startsWith('summary:')) {
        currentSection = 'summary';
        final summaryText = line.substring(line.indexOf(':') + 1).trim();
        if (summaryText.isNotEmpty) {
          currentSummary = summaryText;
        }
        continue;
      } else if (lower.startsWith('actions:') || lower.startsWith('action:')) {
        currentSection = 'actions';
        continue;
      } else if (lower.startsWith('relations:') || lower.startsWith('relationship:') || lower.startsWith('relation:')) {
        currentSection = 'relationships';
        continue;
      }
      
      // Parse content based on current section and character
      if (currentCharacterName != null) {
        if (currentSection == 'summary' || (currentSection == null && !line.startsWith('-') && !line.contains(':'))) {
          // This is summary text
          if (currentSummary!.isEmpty) {
            currentSummary = line;
          } else {
            currentSummary = '$currentSummary $line';
          }
        } else if (currentSection == 'actions' || (line.startsWith('-') || line.startsWith('•'))) {
          // This is an action
          final content = line.replaceAll(RegExp(r'^[-•]\s*'), '').trim();
          if (content.isNotEmpty && !content.toLowerCase().contains('relation')) {
            currentActions.add(content);
          }
        } else if (currentSection == 'relationships' || line.contains(':')) {
          // This might be a relationship
          final parts = line.split(':');
          if (parts.length >= 2) {
            final otherChar = parts[0].trim().replaceAll(RegExp(r'^[-•]\s*'), '');
            final desc = parts.sublist(1).join(':').trim();
            if (otherChar.isNotEmpty && desc.isNotEmpty) {
              currentRelationships[otherChar] = desc;
            }
          }
        }
      }
    }
    
    // Save last character if any
    if (currentCharacterName != null && currentSummary != null && currentSummary.isNotEmpty) {
      notes.add(ChunkCharacterNote(
        name: currentCharacterName,
        summary: currentSummary.trim(),
        notableActions: List.from(currentActions),
        relationships: Map.from(currentRelationships),
      ));
    }
    
    return notes;
  }

  /// Merge new character notes into existing character profiles
  CharacterProfilesPayload _mergeCharacterProfiles(
    CharacterProfilesPayload existingProfiles,
    List<ChunkCharacterNote> newNotes,
    String? chapterTitle,
  ) {
    final updatedProfiles = <CharacterProfile>[];
    final existingProfilesMap = <String, CharacterProfile>{};
    
    // Create map of existing profiles by name (case-insensitive)
    for (final profile in existingProfiles.profiles) {
      existingProfilesMap[profile.name.toLowerCase()] = profile;
    }
    
    // Process new notes
    for (final note in newNotes) {
      final nameKey = note.name.toLowerCase();
      
      if (existingProfilesMap.containsKey(nameKey)) {
        // Update existing profile
        final existing = existingProfilesMap[nameKey]!;
        final updatedEvents = List<String>.from(existing.notableEvents);
        
        // Add new actions
        for (final action in note.notableActions) {
          if (!updatedEvents.contains(action)) {
            updatedEvents.add(action);
          }
        }
        
        // Merge relationships
        final updatedRelationships = List<CharacterRelationship>.from(existing.relationships);
        for (final relEntry in note.relationships.entries) {
          // Check if relationship already exists
          final existingRel = updatedRelationships.where(
            (r) => r.withCharacter.toLowerCase() == relEntry.key.toLowerCase()
          ).firstOrNull;
          
          if (existingRel == null) {
            updatedRelationships.add(CharacterRelationship(
              withCharacter: relEntry.key,
              description: relEntry.value,
            ));
          } else {
            // Update existing relationship if new info is provided
            final index = updatedRelationships.indexOf(existingRel);
            updatedRelationships[index] = CharacterRelationship(
              withCharacter: existingRel.withCharacter,
              description: '${existingRel.description}. ${relEntry.value}',
            );
          }
        }
        
        // Update overview with new information - append new info if it adds value
        String updatedOverview;
        if (existing.overview.isEmpty) {
          updatedOverview = note.summary;
        } else {
          // Only append if the new summary adds new information
          // Check if note.summary is substantially different from existing.overview
          final similarity = _calculateSimilarity(existing.overview, note.summary);
          if (similarity < 0.7) { // If less than 70% similar, it's new information
            updatedOverview = '${existing.overview}\n\n${note.summary}';
          } else {
            updatedOverview = existing.overview;
          }
        }
        
        updatedProfiles.add(CharacterProfile(
          name: existing.name,
          overview: updatedOverview,
          notableEvents: updatedEvents,
          relationships: updatedRelationships,
        ));
      } else {
        // Create new profile
        final relationships = note.relationships.entries.map((e) => 
          CharacterRelationship(
            withCharacter: e.key,
            description: e.value,
          )
        ).toList();
        
        updatedProfiles.add(CharacterProfile(
          name: note.name,
          overview: note.summary,
          notableEvents: List.from(note.notableActions),
          relationships: relationships,
        ));
        
        existingProfilesMap[nameKey] = updatedProfiles.last;
      }
    }
    
    // Add existing profiles that weren't updated
    for (final profile in existingProfiles.profiles) {
      if (!updatedProfiles.any((p) => p.name.toLowerCase() == profile.name.toLowerCase())) {
        updatedProfiles.add(profile);
      }
    }
    
    return CharacterProfilesPayload(profiles: updatedProfiles);
  }

  /// Generate formatted character profiles from structured data
  Future<String> _generateCharacterProfiles(
    CharacterProfilesPayload profilesPayload,
    String bookTitle,
    String language,
  ) async {
    if (profilesPayload.profiles.isEmpty) {
      return language == 'fr' 
          ? 'Aucun personnage trouvé.'
          : 'No characters found.';
    }

    // Format each character profile individually
    final buffer = StringBuffer();
    
    if (language == 'fr') {
      buffer.writeln('## Personnages de "$bookTitle"\n');
    } else {
      buffer.writeln('## Characters in "$bookTitle"\n');
    }
    
    // Sort profiles alphabetically by name
    final sortedProfiles = List<CharacterProfile>.from(profilesPayload.profiles)
      ..sort((a, b) => a.name.compareTo(b.name));
    
    for (final profile in sortedProfiles) {
      // Clean profile data to remove any prompt artifacts
      final cleanOverview = _cleanCharacterText(profile.overview);
      final cleanName = profile.name.trim();
      
      if (cleanName.isEmpty) continue; // Skip invalid profiles
      
      buffer.writeln('### $cleanName\n');
      
      if (cleanOverview.isNotEmpty) {
        buffer.writeln('**${language == 'fr' ? "Résumé" : "Overview"}:**');
        buffer.writeln('$cleanOverview\n');
      }
      
      if (profile.notableEvents.isNotEmpty) {
        buffer.writeln('**${language == 'fr' ? "Événements remarquables" : "Notable Events"}:**');
        for (final event in profile.notableEvents) {
          final cleanEvent = _cleanCharacterText(event);
          if (cleanEvent.isNotEmpty) {
            buffer.writeln('- $cleanEvent');
          }
        }
        buffer.writeln('');
      }
      
      if (profile.relationships.isNotEmpty) {
        buffer.writeln('**${language == 'fr' ? "Relations" : "Relationships"}:**');
        for (final rel in profile.relationships) {
          final cleanRelChar = rel.withCharacter.trim();
          final cleanRelDesc = _cleanCharacterText(rel.description);
          if (cleanRelChar.isNotEmpty && cleanRelDesc.isNotEmpty) {
            buffer.writeln('- **$cleanRelChar**: $cleanRelDesc');
          }
        }
        buffer.writeln('');
      }
      
      buffer.writeln('---\n');
    }
    
    return buffer.toString().trim();
  }

  /// Build a prompt for chunk summarization using custom prompts
  String _buildChunkSummaryPrompt(String text, String? chunkTitle, String language) {
    var promptTemplate = _promptConfigService.getChunkSummaryPrompt(language);
    
    // Add chapter title if provided
    if (chunkTitle != null) {
      if (language == 'fr') {
        promptTemplate = 'Chapitre: $chunkTitle\n\n$promptTemplate';
      } else {
        promptTemplate = 'Chapter: $chunkTitle\n\n$promptTemplate';
      }
    }
    
    return _promptConfigService.formatPrompt(promptTemplate, text: text);
  }

  /// Clean character text - minimal cleaning for edge cases only
  /// Most cleaning should be handled by proper prompts, not post-processing
  String _cleanCharacterText(String text) {
    if (text.isEmpty) return text;
    
    // Only trim whitespace - prompts should handle the rest
    var cleaned = text.trim();
    
    // Remove leading labels if they somehow appear (shouldn't with proper prompts)
    final labelPatterns = [
      RegExp(r'^(résumé:|summary:|overview:)\s+', caseSensitive: false),
      RegExp(r'^(actions?:|événements?:|events?:)\s+', caseSensitive: false),
      RegExp(r'^(relations?:|relationships?:)\s+', caseSensitive: false),
    ];
    
    for (final pattern in labelPatterns) {
      cleaned = cleaned.replaceFirst(pattern, '');
    }
    
    return cleaned.trim();
  }

  /// Update the last summary view position
  Future<void> updateLastSummaryView(String bookId, int chunkIndex) async {
    await _dbService.updateLastSummaryView(bookId, chunkIndex);
  }

  /// Update the last reading stop position (when user stops reading)
  Future<void> updateLastReadingStop(
    String bookId, {
    required int chunkIndex,
    required int characterIndex,
    double? progress,
  }) async {
    await _dbService.updateLastReadingStop(
      bookId,
      chunkIndex: chunkIndex,
      characterIndex: characterIndex,
      progress: progress,
    );
  }

  /// Delete all summaries for a book
  Future<void> deleteBookSummaries(String bookId) async {
    await _dbService.deleteBookSummaries(bookId);
  }

  Future<void> resetGeneralSummary(String bookId) async {
    await _dbService.clearGeneralSummary(bookId);
    // Clear API cache for this book
    final apiCacheService = ApiCacheService();
    await apiCacheService.clearCacheForBook(bookId);
  }

  Future<void> resetSinceLastTimeSummary(String bookId) async {
    await _dbService.clearSinceLastTimeSummary(bookId);
    // Clear API cache for this book
    final apiCacheService = ApiCacheService();
    await apiCacheService.clearCacheForBook(bookId);
  }

  Future<void> resetCharactersSummary(String bookId) async {
    await _dbService.clearCharactersSummary(bookId);
    // Clear API cache for this book
    final apiCacheService = ApiCacheService();
    await apiCacheService.clearCacheForBook(bookId);
  }

  Future<void> resetAllSummaries() async {
    await _dbService.clearAll();
  }
}

