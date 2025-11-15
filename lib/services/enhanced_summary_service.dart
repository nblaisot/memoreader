import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:epubx/epubx.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import '../utils/html_text_extractor.dart';
import '../utils/text_tokenizer.dart';

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
        maxChunkTokens: 12000,
        overlapTokens: 260,
        maxChunksPerBatch: 6,
        maxAggregateTokens: 65000,
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
        maxChunkTokens: 12000,
        overlapTokens: 260,
        maxChunksPerBatch: 6,
        maxAggregateTokens: 30000,  // Slightly more conservative than OpenAI
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

  int get _maxTokensPerChunk => _chunkConfig.maxChunkTokens;
  int get _chunkOverlapTokens => _chunkConfig.overlapTokens;
  int get _maxChunksPerBatch => _chunkConfig.maxChunksPerBatch;
  int get _maxCumulativeTokens => _chunkConfig.maxAggregateTokens;
  int get _safeChunkTokens => _chunkConfig.safeChunkTokens;

  EnhancedSummaryService(this._baseSummaryService, SharedPreferences prefs)
      : _chunkConfig = ChunkingConfig.resolve(_baseSummaryService),
        _promptConfigService = PromptConfigService(prefs);

  Future<String> runCustomPrompt(String prompt, String languageCode) async {
    return await _baseSummaryService.generateSummary(prompt, languageCode);
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

  /// Extract text from book from beginning up to a specific word index.
  /// Returns a list of chapter texts, where the last chapter may be truncated.
  Future<List<ChapterText>> _extractTextUpToWordIndex(
    Book book,
    int targetWordIndex,
  ) async {
    final epub = await _bookService.loadEpubBook(book.filePath);
    final chapters = _parseChapters(epub);
    
    if (chapters.isEmpty) {
      return [];
    }

    final result = <ChapterText>[];
    int currentWordCount = 0;

    for (final chapter in chapters) {
      final htmlText = chapter.htmlContent;
      final plainText = _extractTextFromHtml(htmlText);
      
      if (plainText.isEmpty) continue;

      final words = tokenizePreservingWhitespace(plainText);
      final chapterWordCount = words.length;

      if (currentWordCount + chapterWordCount <= targetWordIndex) {
        // Entire chapter fits
        result.add(ChapterText(
          chapterIndex: chapter.index,
          title: chapter.title,
          text: plainText,
          isComplete: true,
        ));
        currentWordCount += chapterWordCount;
      } else {
        // Partial chapter - extract only up to targetWordIndex
        final remainingWords = targetWordIndex - currentWordCount;
        if (remainingWords > 0) {
          final partialWords = words.sublist(0, remainingWords);
          final partialText = partialWords.join('');
          result.add(ChapterText(
            chapterIndex: chapter.index,
            title: chapter.title,
            text: partialText,
            isComplete: false,
          ));
        }
        break; // We've reached the target
      }
    }

    return result;
  }

  /// Extract text from book up to a specific character index
  /// This is the new method that uses characterIndex instead of wordIndex
  Future<List<ChapterText>> _extractTextUpToCharacterIndex(
    Book book,
    int targetCharacterIndex,
  ) async {
    final epub = await _bookService.loadEpubBook(book.filePath);
    final chapters = _parseChapters(epub);
    
    if (chapters.isEmpty) {
      return [];
    }

    final result = <ChapterText>[];
    int currentCharacterCount = 0;

    for (final chapter in chapters) {
      final htmlText = chapter.htmlContent;
      final plainText = _extractTextFromHtml(htmlText);
      
      if (plainText.isEmpty) continue;

      final chapterCharacterCount = plainText.length;

      if (currentCharacterCount + chapterCharacterCount <= targetCharacterIndex) {
        // Entire chapter fits
        result.add(ChapterText(
          chapterIndex: chapter.index,
          title: chapter.title,
          text: plainText,
          isComplete: true,
        ));
        currentCharacterCount += chapterCharacterCount;
      } else {
        // Partial chapter - extract only up to targetCharacterIndex
        final remainingCharacters = targetCharacterIndex - currentCharacterCount;
        if (remainingCharacters > 0) {
          final partialText = plainText.substring(0, remainingCharacters);
          result.add(ChapterText(
            chapterIndex: chapter.index,
            title: chapter.title,
            text: partialText,
            isComplete: false,
          ));
        }
        break; // We've reached the target
      }
    }

    return result;
  }

  /// Estimate token count (rough approximation: 1 token ≈ 4 characters)
  int _estimateTokenCount(String text) {
    return (text.length / 4).round();
  }

  /// Estimate character index from word index (for backward compatibility)
  /// This is a rough approximation: average word length is ~5 characters + 1 space
  int _estimateCharacterIndexFromWordIndex(int wordIndex, Book book) {
    // Rough estimate: 6 characters per word on average
    return wordIndex * 6;
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
  Future<String> _generateChunkSummary(String text, String? chunkTitle, String language) async {
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
      final summary = await _baseSummaryService.generateSummary(prompt, language);
      
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

  /// Generate cumulative summary from multiple chunk summaries
  Future<String> _generateCumulativeSummary(
    List<String> chunkSummaries,
    String bookTitle,
    String language,
  ) async {
    if (chunkSummaries.isEmpty) {
      return 'No content to summarize.';
    }

    // For now, combine summaries with headers
    // In the future, we could use the LLM to create a more cohesive summary
    final combined = chunkSummaries
        .asMap()
        .entries
        .map((e) => '## Chapter ${e.key + 1}\n\n${e.value}')
        .join('\n\n---\n\n');

    // If we have many chunks, create a summary of summaries
    if (chunkSummaries.length > 5) {
      // Create a concise summary by summarizing the combined text
      final summaryText = combined.length > _maxCumulativeTokens * 4
          ? combined.substring(0, _maxCumulativeTokens * 4)
          : combined;
      
      try {
        // Use improved prompt with anti-leakage instructions
        final prompt = _buildFallbackSummaryPrompt(summaryText, bookTitle, language);
        return await _baseSummaryService.generateSummary(prompt, language);
      } catch (e) {
        // If summarization fails, return the combined summaries
        debugPrint('Error generating cumulative summary: $e');
        return '## Summary of $bookTitle\n\n$combined';
      }
    }

    return '## Summary of $bookTitle\n\n$combined';
  }

  /// Generate a concise summary from an existing cumulative summary
  Future<String> _generateConciseSummary(
    String fullSummary,
    String bookTitle,
    String language,
  ) async {
    try {
      // Use improved prompt with anti-leakage instructions
      final prompt = _buildConciseSummaryPrompt(fullSummary, bookTitle, language);
      return await _baseSummaryService.generateSummary(prompt, language);
    } catch (e) {
      debugPrint('Error generating concise summary: $e');
      // Fallback: return first few sentences
      final sentences = fullSummary.split('.');
      return sentences.take(4).join('.') + '.';
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
    String language,
  ) async {
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
        );
        batchSummaries.add(batchSummary);
      }

      // Combine batch summaries into final narrative
      narrative = await _synthesizeNarrative(
        batchSummaries,
        bookTitle,
        language,
      );
    } else {
      // Small enough to process directly
      narrative = await _synthesizeNarrative(
        summaryTexts,
        bookTitle,
        language,
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
    String language,
  ) async {
    // Remove duplicates before combining
    final uniqueSummaries = _removeDuplicateSummaries(chapterSummaries);
    if (uniqueSummaries.isEmpty) {
      debugPrint('No unique summaries to combine in batch');
      return '';
    }
    
    final combined = uniqueSummaries.join(' ');
    final prompt = _buildBatchSummaryPrompt(combined, language);

    try {
      return await _baseSummaryService.generateSummary(prompt, language);
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
    String language,
  ) async {
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
      final narrative = await _baseSummaryService.generateSummary(prompt, language);
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
      bookTitle: bookTitle,
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
    String languageCode,
  ) async {
    try {
      // Use currentCharacterIndex if available, fallback to currentWordIndex for backward compatibility
      final currentCharacterIndex = progress.currentCharacterIndex ?? 
          (progress.currentWordIndex != null ? _estimateCharacterIndexFromWordIndex(progress.currentWordIndex!, book) : 0);
      final language = _getLanguage(languageCode);
      
      if (currentCharacterIndex <= 0) {
        return 'No content read yet.';
      }

      // Extract text up to the exact character index
      final chapterTexts = await _extractTextUpToCharacterIndex(book, currentCharacterIndex);
      
      if (chapterTexts.isEmpty) {
        throw Exception('No content found in book');
      }

      // Check cache - we need to check if cached summary covers at least currentCharacterIndex
      final cache = await _dbService.getSummaryCache(book.id);
      final cachedCharacterIndex = cache?.lastProcessedCharacterIndex ?? -1;
      
      if (cache != null &&
          cachedCharacterIndex == currentCharacterIndex &&
          cache.cumulativeSummary.isNotEmpty) {
        // Return cached summary if it covers the current position
        return cache.cumulativeSummary;
      }

      // Process chapters that haven't been processed yet
      final lastProcessedCharacterIndex = cachedCharacterIndex;
      final chaptersToProcess = <ChapterText>[];
      
      int characterOffset = 0;
      for (final chapterText in chapterTexts) {
        final chapterCharacterCount = chapterText.text.length;
        final chapterStartCharacterIndex = characterOffset;
        final chapterEndCharacterIndex = characterOffset + chapterCharacterCount - 1;
        
        if (chapterEndCharacterIndex > lastProcessedCharacterIndex) {
          // This chapter needs processing (or re-processing if partially processed)
          if (chapterStartCharacterIndex <= lastProcessedCharacterIndex) {
            // Partial chapter - extract only the new part
            final processedCharacters = lastProcessedCharacterIndex - chapterStartCharacterIndex + 1;
            if (processedCharacters < chapterText.text.length) {
              final newText = chapterText.text.substring(processedCharacters);
              if (newText.trim().isNotEmpty) {
                chaptersToProcess.add(ChapterText(
                  chapterIndex: chapterText.chapterIndex,
                  title: chapterText.title,
                  text: newText,
                  isComplete: chapterText.isComplete,
                ));
              }
            }
          } else {
            // Entire chapter needs processing
            chaptersToProcess.add(chapterText);
          }
        }
        
        characterOffset += chapterCharacterCount;
      }

      // Process new chapters
      for (final chapterText in chaptersToProcess) {
        final plainText = chapterText.text;
        if (plainText.isEmpty) continue;

        try {
          // Check if text is too large and needs splitting
          final safeMaxTokens = _maxTokensPerChunk ~/ 2;
          final textChunks = _splitTextIntoChunks(plainText, safeMaxTokens);
          
          String combinedSummary = '';
          for (int j = 0; j < textChunks.length; j++) {
            try {
              final chunkText = textChunks[j];
              final chunkTitle = (j == 0) ? chapterText.title : null;
              final summary = await _generateChunkSummary(chunkText, chunkTitle, language);
              
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
              debugPrint('Error processing chunk $j of chapter ${chapterText.chapterIndex}: $e');
            }
          }
          
          if (combinedSummary.isEmpty) {
            debugPrint('No valid summary generated for chapter ${chapterText.title}, skipping');
            continue;
          }

          // Save chunk summary using chapter index as chunk index
          final tokenCount = _estimateTokenCount(plainText);
          final summaryChunk = BookSummaryChunk(
            bookId: book.id,
            chunkIndex: chapterText.chapterIndex,
            chunkType: ChunkType.chapter,
            summaryText: combinedSummary,
            tokenCount: tokenCount,
            createdAt: DateTime.now(),
          );

          await _dbService.saveSummaryChunk(summaryChunk);
        } catch (e) {
          debugPrint('Error processing chapter ${chapterText.chapterIndex}: $e');
        }
      }

      // Get all chunk summaries up to current position
      // We need to get summaries for all chapters up to the last chapter in chapterTexts
      final maxChapterIndex = chapterTexts.isNotEmpty 
          ? chapterTexts.last.chapterIndex 
          : 0;
      final allChunkSummaries = await _dbService.getSummaryChunks(book.id, maxChapterIndex);
      
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
          debugPrint('Filtering out invalid cached summary for chunk ${chunk.chunkIndex}');
          return false;
        }
        return true;
      }).toList();
      
      if (validChunkSummaries.isEmpty) {
        throw Exception('No valid summaries available');
      }

      // Generate hierarchical summary with structured data
      final generalSummary = await _generateGeneralSummary(
        validChunkSummaries,
        book.title,
        language,
      );
      
      // Format for display
      final narrative = _formatGeneralSummary(generalSummary);

      // Update cache with structured and text summary
      final updatedCache = (cache ?? BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: maxChapterIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
      )).copyWith(
        lastProcessedChunkIndex: maxChapterIndex,
        lastProcessedCharacterIndex: currentCharacterIndex,
        cumulativeSummary: narrative,
        generalSummaryJson: generalSummary.toJsonString(),
        generalSummaryUpdatedAt: DateTime.now(),
        lastUpdated: DateTime.now(),
      );
      await _dbService.saveSummaryCache(updatedCache);

      return narrative;
    } catch (e) {
      debugPrint('Error generating summary up to position: $e');
      rethrow;
    }
  }

  /// Get summary since last reading session
  /// Uses currentCharacterIndex to extract text exactly up to the reading position
  Future<String> getSummarySinceLastTime(
    Book book,
    ReadingProgress progress,
    String languageCode,
  ) async {
    try {
      // Use currentCharacterIndex if available, fallback to currentWordIndex for backward compatibility
      final currentCharacterIndex = progress.currentCharacterIndex ?? 
          (progress.currentWordIndex != null ? _estimateCharacterIndexFromWordIndex(progress.currentWordIndex!, book) : 0);
      final language = _getLanguage(languageCode);
      
      // Get cache to find last reading stop
      final cache = await _dbService.getSummaryCache(book.id);
      // Use characterIndex if available, fallback to wordIndex for backward compatibility
      final lastReadingStopCharacterIndex = cache?.lastReadingStopCharacterIndex ??
          (cache?.lastReadingStopWordIndex != null ? _estimateCharacterIndexFromWordIndex(cache!.lastReadingStopWordIndex!, book) : null);
      final lastReadingStopTimestamp = cache?.lastReadingStopTimestamp;
      final previousReadingStopCharacterIndex = cache?.previousReadingStopCharacterIndex ??
          (cache?.previousReadingStopWordIndex != null ? _estimateCharacterIndexFromWordIndex(cache!.previousReadingStopWordIndex!, book) : null);

      // Check if we have a cached "since last time" summary that's still valid
      final cachedSinceLastTimeCharacterIndex = cache?.summarySinceLastTimeCharacterIndex ??
          (cache?.summarySinceLastTimeWordIndex != null ? _estimateCharacterIndexFromWordIndex(cache!.summarySinceLastTimeWordIndex!, book) : null);
      if (cache != null &&
          cache.summarySinceLastTime != null &&
          cachedSinceLastTimeCharacterIndex == currentCharacterIndex &&
          lastReadingStopCharacterIndex == cache.lastReadingStopCharacterIndex) {
        return cache.summarySinceLastTime!;
      }

      // Determine the session range
      // "Since last time" shows the last completed reading session
      // Session starts from previousReadingStopCharacterIndex (or 0 if none) to lastReadingStopCharacterIndex
      // This is the session that ended when the user last stopped reading
      final sessionStartCharacterIndex = previousReadingStopCharacterIndex ?? 0;
      final sessionEndCharacterIndex = lastReadingStopCharacterIndex;

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
          final beginningTexts = await _extractTextUpToCharacterIndex(book, endIndex);
          if (beginningTexts.isEmpty) {
            final fallback = language == 'fr'
                ? 'Impossible de générer un résumé concis du début.'
                : 'Unable to generate a concise beginning summary.';
            return '$heading\n\n$fallback';
          }

          final beginningText = beginningTexts.map((ct) => ct.text).join('\n\n');
          if (beginningText.trim().isEmpty) {
            final fallback = language == 'fr'
                ? 'Impossible de générer un résumé concis du début.'
                : 'Unable to generate a concise beginning summary.';
            return '$heading\n\n$fallback';
          }

          final beginningSummary = await _generateChunkSummary(beginningText, null, language);
          final conciseBeginning = await _generateConciseSummary(beginningSummary, book.title, language);
          final trimmed = conciseBeginning.trim();
          if (trimmed.isEmpty) {
            final fallback = language == 'fr'
                ? 'Impossible de générer un résumé concis du début.'
                : 'Unable to generate a concise beginning summary.';
            return '$heading\n\n$fallback';
          }
          return '$heading\n\n$trimmed';
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

      // If no reading stops recorded, or user hasn't completed a session yet
      if (lastReadingStopCharacterIndex == null ||
          sessionEndCharacterIndex == null ||
          sessionEndCharacterIndex >= currentCharacterIndex) {
        // First reading session or no new content - show what they've read so far
        final conciseBeginningSection =
            await buildConciseBeginningSection(currentCharacterIndex);

        String timestampText = '';
        if (lastReadingStopTimestamp != null) {
          timestampText = _formatTimestamp(lastReadingStopTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noCompletedSessionMessage()}';
      }

      if (sessionStartCharacterIndex >= sessionEndCharacterIndex) {
        final conciseBeginningSection =
            await buildConciseBeginningSection(sessionStartCharacterIndex);

        String timestampText = '';
        if (lastReadingStopTimestamp != null) {
          timestampText = _formatTimestamp(lastReadingStopTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noSessionContentMessage()}';
      }

      // Get concise summary of beginning (up to sessionStartCharacterIndex) for context
      final conciseBeginningSection =
          await buildConciseBeginningSection(sessionStartCharacterIndex);

      // Extract text for the session (from sessionStartCharacterIndex to sessionEndCharacterIndex)
      final sessionEndTexts = await _extractTextUpToCharacterIndex(book, sessionEndCharacterIndex);
      
      // Calculate the text that belongs to the session
      String sessionText = '';
      int characterOffset = 0;
      
      for (final chapterText in sessionEndTexts) {
        final chapterCharacterCount = chapterText.text.length;
        final chapterStartCharacterIndex = characterOffset;
        final chapterEndCharacterIndex = characterOffset + chapterCharacterCount - 1;
        
        if (chapterEndCharacterIndex >= sessionStartCharacterIndex && chapterStartCharacterIndex < sessionEndCharacterIndex) {
          // This chapter overlaps with the session
          int startInChapter = 0;
          int endInChapter = chapterCharacterCount;
          
          if (chapterStartCharacterIndex < sessionStartCharacterIndex) {
            startInChapter = sessionStartCharacterIndex - chapterStartCharacterIndex;
          }
          if (chapterEndCharacterIndex > sessionEndCharacterIndex) {
            endInChapter = sessionEndCharacterIndex - chapterStartCharacterIndex + 1;
          }
          
          if (endInChapter > startInChapter) {
            final sessionChapterText = chapterText.text.substring(startInChapter, endInChapter);
            if (sessionText.isNotEmpty) {
              sessionText = '$sessionText\n\n$sessionChapterText';
            } else {
              sessionText = sessionChapterText;
            }
          }
        }
        
        characterOffset += chapterCharacterCount;
      }

      if (sessionText.trim().isEmpty) {
        String timestampText = '';
        if (lastReadingStopTimestamp != null) {
          timestampText = _formatTimestamp(lastReadingStopTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noNewContentMessage()}';
      }

      // Generate summary of the session text
      final safeMaxTokens = _maxTokensPerChunk ~/ 2;
      final textChunks = _splitTextIntoChunks(sessionText, safeMaxTokens);
      
      String combinedSummary = '';
      for (final chunkText in textChunks) {
        try {
          final summary = await _generateChunkSummary(chunkText, null, language);
          
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
        if (lastReadingStopTimestamp != null) {
          timestampText = _formatTimestamp(lastReadingStopTimestamp, languageCode);
        }
        final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
        return '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n${noNewContentMessage()}';
      }

      // Format timestamp for display
      String timestampText = '';
      if (lastReadingStopTimestamp != null) {
        timestampText = _formatTimestamp(lastReadingStopTimestamp, languageCode);
      }

      // Combine: concise beginning + "Since last time:" + session summary
      final sinceLastTimeHeader = buildSinceLastTimeHeader(timestampText);
      final fullSummary =
          '${conciseBeginningSection.trim()}\n\n$sinceLastTimeHeader\n\n$combinedSummary';
      
      // Cache the generated summary
      final maxChapterIndex = sessionEndTexts.isNotEmpty 
          ? sessionEndTexts.last.chapterIndex 
          : 0;
      final updatedCache = (cache ?? BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: maxChapterIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
      )).copyWith(
        summarySinceLastTime: fullSummary,
        summarySinceLastTimeChunkIndex: maxChapterIndex,
        summarySinceLastTimeCharacterIndex: currentCharacterIndex,
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
    String languageCode,
  ) async {
    try {
      // Use currentCharacterIndex if available, fallback to currentWordIndex for backward compatibility
      final currentCharacterIndex = progress.currentCharacterIndex ?? 
          (progress.currentWordIndex != null ? _estimateCharacterIndexFromWordIndex(progress.currentWordIndex!, book) : 0);
      final language = _getLanguage(languageCode);
      
      if (currentCharacterIndex <= 0) {
        return 'No content read yet.';
      }

      // Extract text up to the exact character index
      final chapterTexts = await _extractTextUpToCharacterIndex(book, currentCharacterIndex);
      
      if (chapterTexts.isEmpty) {
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

      // Process chapters that haven't been processed yet
      int characterOffset = 0;
      for (final chapterText in chapterTexts) {
        final chapterCharacterCount = chapterText.text.length;
        final chapterStartCharacterIndex = characterOffset;
        final chapterEndCharacterIndex = characterOffset + chapterCharacterCount - 1;
        
        if (chapterEndCharacterIndex > lastCharacterProcessedCharacterIndex) {
          // This chapter needs processing (or re-processing if partially processed)
          String textToProcess = chapterText.text;
          
          if (chapterStartCharacterIndex <= lastCharacterProcessedCharacterIndex) {
            // Partial chapter - extract only the new part
            final processedCharacters = lastCharacterProcessedCharacterIndex - chapterStartCharacterIndex + 1;
            if (processedCharacters < chapterText.text.length) {
              textToProcess = chapterText.text.substring(processedCharacters);
            } else {
              textToProcess = '';
            }
          }
          
          if (textToProcess.trim().isNotEmpty) {
            try {
              // Extract character information from this text
              final chapterCharacterNotes = await _extractCharactersFromText(
                textToProcess,
                chapterText.title,
                language,
                existingCharacterNames,
              );
              
              // Update character profiles with new information
              existingProfiles = _mergeCharacterProfiles(
                existingProfiles,
                chapterCharacterNotes,
                chapterText.title,
              );
              
              // Update existing character names set
              for (final profile in existingProfiles.profiles) {
                existingCharacterNames.add(profile.name.toLowerCase());
              }
            } catch (e) {
              debugPrint('Error processing chapter ${chapterText.chapterIndex} for characters: $e');
              // Continue with next chapter
            }
          }
        }
        
        characterOffset += chapterCharacterCount;
      }

      // Generate final character profiles using structured data
      final charactersSummary = await _generateCharacterProfiles(
        existingProfiles,
        book.title,
        language,
      );

      // Cache the structured character profiles
      final maxChapterIndex = chapterTexts.isNotEmpty 
          ? chapterTexts.last.chapterIndex 
          : 0;
      final updatedCache = (cache ?? BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: maxChapterIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
      )).copyWith(
        characterProfilesJson: existingProfiles.toJsonString(),
        characterProfilesUpdatedAt: DateTime.now(),
        charactersSummary: charactersSummary,
        charactersSummaryChunkIndex: maxChapterIndex,
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
    Set<String> existingCharacterNames,
  ) async {
    try {
      // Limit text size based on service capabilities
      final maxLength = _chunkConfig.safeChunkTokens * 4; // Rough char estimate
      final safeText = text.length > maxLength 
          ? '${text.substring(0, maxLength)}...'
          : text;

      // Build prompt with explicit instructions to avoid prompt leakage
      final prompt = _buildCharacterExtractionPrompt(safeText, language);

      try {
        final response = await _baseSummaryService.generateSummary(prompt, language);
        
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

  /// Build a prompt for fallback summary generation using custom prompts
  String _buildFallbackSummaryPrompt(String summaryText, String bookTitle, String language) {
    final promptTemplate = _promptConfigService.getFallbackSummaryPrompt(language);
    return _promptConfigService.formatPrompt(
      promptTemplate,
      text: summaryText,
      bookTitle: bookTitle,
    );
  }

  /// Build a prompt for concise summary generation using custom prompts
  String _buildConciseSummaryPrompt(String fullSummary, String bookTitle, String language) {
    final promptTemplate = _promptConfigService.getConciseSummaryPrompt(language);
    return _promptConfigService.formatPrompt(
      promptTemplate,
      text: fullSummary,
      bookTitle: bookTitle,
    );
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
    int? wordIndex,
  }) async {
    await _dbService.updateLastReadingStop(
      bookId,
      chunkIndex: chunkIndex,
      characterIndex: characterIndex,
      wordIndex: wordIndex,
    );
  }

  /// Delete all summaries for a book
  Future<void> deleteBookSummaries(String bookId) async {
    await _dbService.deleteBookSummaries(bookId);
  }

  Future<void> resetAllSummaries() async {
    await _dbService.clearAll();
  }
}

