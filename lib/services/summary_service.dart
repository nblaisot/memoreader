import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epubx/epubx.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../models/book_summary_chunk.dart';
import '../models/book_summary_cache.dart';
import 'summary_database_service.dart';
import 'book_service.dart';
import 'api_cost_service.dart';

class SummaryService {
  final SummaryDatabaseService _dbService = SummaryDatabaseService();
  final BookService _bookService = BookService();
  final ApiCostService _costService = ApiCostService();

  // OpenAI API configuration
  static const String _apiUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o-mini';

  // Configuration constants
  static const int _maxTokensPerChunk = 15000; // Max tokens per chunk input
  static const int _maxCumulativeTokens = 50000; // Max tokens for cumulative summary
  static const int _chunkOverlap = 500; // Token overlap between chunks for context

  // API Key should be stored securely - using SharedPreferences for now
  // TODO: Consider using flutter_secure_storage for production
  Future<String?> _getApiKey() async {
    // For now, returning null - user will need to set API key in settings
    // In production, this should come from secure storage
    return null;
  }

  Future<void> setApiKey(String apiKey) async {
    // Store API key in SharedPreferences
    // This is a simple implementation - consider using flutter_secure_storage
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('openai_api_key', apiKey);
  }

  Future<String?> _getStoredApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('openai_api_key');
    } catch (e) {
      debugPrint('Error getting API key: $e');
      return null;
    }
  }

  /// Extract plain text from HTML content
  String _extractTextFromHtml(String htmlContent) {
    try {
      final document = html_parser.parse(htmlContent);
      return document.body?.text ?? '';
    } catch (e) {
      debugPrint('Error parsing HTML: $e');
      // Fallback: remove HTML tags using regex
      return htmlContent
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
  }

  /// Estimate token count (rough approximation: 1 token ≈ 4 characters)
  int _estimateTokenCount(String text) {
    return (text.length / 4).round();
  }

  /// Generate summary for a single chunk using OpenAI API
  Future<String> _generateChunkSummary(String text, String? chunkTitle) async {
    final apiKey = await _getStoredApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('OpenAI API key not configured. Please set it in settings.');
    }

    final languageInstruction = _getLanguageInstruction();
    final prompt = chunkTitle != null
        ? '''$languageInstruction

Summarize the following chapter from a book. Focus on key plot points, character development, and important events. Be concise but comprehensive.

Chapter Title: $chunkTitle

Chapter Content:
$text

Summary:'''
        : '''$languageInstruction

Summarize the following section from a book. Focus on key plot points, character development, and important events. Be concise but comprehensive.

Section Content:
$text

Summary:''';

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.3,
          'max_tokens': 1000, // Limit summary length
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Track API costs
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final promptTokens = usage['prompt_tokens'] as int? ?? 0;
          final completionTokens = usage['completion_tokens'] as int? ?? 0;
          await _costService.addCost(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
          );
        }
        
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null && content.isNotEmpty) {
          return content.trim();
        } else {
          throw Exception('Empty response from OpenAI API');
        }
      } else {
        final errorData = jsonDecode(response.body) as Map<String, dynamic>;
        final errorMessage = errorData['error']?['message'] ?? 'Unknown error';
        throw Exception('OpenAI API error: $errorMessage');
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to generate summary: $e');
    }
  }

  /// Generate a very concise summary from an existing cumulative summary
  Future<String> _generateConciseSummary(
    String fullSummary,
    String bookTitle,
  ) async {
    final apiKey = await _getStoredApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('OpenAI API key not configured. Please set it in settings.');
    }

    final languageInstruction = _getLanguageInstruction();
    final prompt = '''$languageInstruction

Create a very concise summary of this book so far in just 3-4 sentences. Focus only on the most essential plot points and character developments.

Book Title: $bookTitle

Full Summary:
$fullSummary

Concise Summary (3-4 sentences):''';

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.3,
          'max_tokens': 200, // Very concise
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Track API costs
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final promptTokens = usage['prompt_tokens'] as int? ?? 0;
          final completionTokens = usage['completion_tokens'] as int? ?? 0;
          await _costService.addCost(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
          );
        }
        
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null && content.isNotEmpty) {
          return content.trim();
        } else {
          throw Exception('Empty response from OpenAI API');
        }
      } else {
        final errorData = jsonDecode(response.body) as Map<String, dynamic>;
        final errorMessage = errorData['error']?['message'] ?? 'Unknown error';
        throw Exception('OpenAI API error: $errorMessage');
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to generate concise summary: $e');
    }
  }

  /// Generate cumulative summary from multiple chunk summaries
  Future<String> _generateCumulativeSummary(
    List<String> chunkSummaries,
    String bookTitle,
  ) async {
    final apiKey = await _getStoredApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('OpenAI API key not configured. Please set it in settings.');
    }

    final combinedSummaries = chunkSummaries
        .asMap()
        .entries
        .map((e) => 'Chapter ${e.key + 1} Summary:\n${e.value}')
        .join('\n\n');

    final languageInstruction = _getLanguageInstruction();
    final prompt = '''$languageInstruction

You are summarizing a book from the beginning up to the current reading point. Combine the following chapter summaries into a cohesive, comprehensive summary of the story so far. Maintain narrative flow and focus on the overall plot progression, character development, and key events.

Book Title: $bookTitle

Chapter Summaries:
$combinedSummaries

Comprehensive Summary of the Story So Far:''';

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.3,
          'max_tokens': 2000, // Longer summary for cumulative
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Track API costs
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final promptTokens = usage['prompt_tokens'] as int? ?? 0;
          final completionTokens = usage['completion_tokens'] as int? ?? 0;
          await _costService.addCost(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
          );
        }
        
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null && content.isNotEmpty) {
          return content.trim();
        } else {
          throw Exception('Empty response from OpenAI API');
        }
      } else {
        final errorData = jsonDecode(response.body) as Map<String, dynamic>;
        final errorMessage = errorData['error']?['message'] ?? 'Unknown error';
        throw Exception('OpenAI API error: $errorMessage');
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to generate cumulative summary: $e');
    }
  }

  /// Get language instruction for prompt - tells LLM to match the language of the text
  String _getLanguageInstruction() {
    return 'IMPORTANT: Write your summary in the same language as the text provided. Match the language of the source material exactly.';
  }

  /// Split text into chunks if it's too large
  List<String> _splitTextIntoChunks(String text, int maxTokens) {
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
      final paraTokenCount = _estimateTokenCount(paragraph);

      if (currentTokenCount + paraTokenCount > maxTokens && currentChunk.isNotEmpty) {
        chunks.add(currentChunk.trim());
        // Add overlap
        final overlapWords = currentChunk.split(' ').take(100).join(' ');
        currentChunk = '$overlapWords $paragraph';
        currentTokenCount = _estimateTokenCount(currentChunk);
      } else {
        currentChunk += '$paragraph\n\n';
        currentTokenCount += paraTokenCount;
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.trim());
    }

    return chunks;
  }

  /// Get or generate summary up to the current reading position
  Future<String> getSummaryUpToPosition(
    Book book,
    ReadingProgress progress,
  ) async {
    try {
      // Load EPUB to get chapters
      final epub = await _bookService.loadEpubBook(book.filePath);
      final chapters = _parseChapters(epub);

      if (chapters.isEmpty) {
        throw Exception('No chapters found in book');
      }

      final currentChunkIndex = progress.currentChapterIndex;
      
      // Check if we have a cached summary that's up to date
      final cache = await _dbService.getSummaryCache(book.id);
      if (cache != null && cache.lastProcessedChunkIndex >= currentChunkIndex) {
        // Return cached summary if it covers the current position
        return cache.cumulativeSummary;
      }

      // Get existing chunk summaries
      final existingChunks = await _dbService.getSummaryChunks(book.id, currentChunkIndex);
      final lastProcessedIndex = await _dbService.getLastProcessedChunkIndex(book.id);

      // Process new chunks from lastProcessedIndex + 1 to currentChunkIndex
      for (int i = lastProcessedIndex + 1; i <= currentChunkIndex; i++) {
        if (i >= chapters.length) break;

        final chapter = chapters[i];
        final htmlText = chapter.htmlContent;
        final plainText = _extractTextFromHtml(htmlText);
        
        if (plainText.isEmpty) continue;

        // Check if text is too large and needs splitting
        final textChunks = _splitTextIntoChunks(plainText, _maxTokensPerChunk);
        
        String combinedSummary = '';
        for (int j = 0; j < textChunks.length; j++) {
          final chunkText = textChunks[j];
          // Only use chapter title for the first chunk
          final chunkTitle = (j == 0) ? chapter.title : null;
          final summary = await _generateChunkSummary(chunkText, chunkTitle);
          if (j == 0) {
            combinedSummary = summary;
          } else {
            // Combine summaries if chapter was split
            combinedSummary = '$combinedSummary\n\n$summary';
          }
        }

        // Save chunk summary
        final tokenCount = _estimateTokenCount(plainText);
        final summaryChunk = BookSummaryChunk(
          bookId: book.id,
          chunkIndex: i,
          chunkType: ChunkType.chapter,
          summaryText: combinedSummary,
          tokenCount: tokenCount,
          createdAt: DateTime.now(),
        );

        await _dbService.saveSummaryChunk(summaryChunk);
      }

      // Get all chunk summaries up to current position
      final allChunkSummaries = await _dbService.getSummaryChunks(book.id, currentChunkIndex);
      
      if (allChunkSummaries.isEmpty) {
        throw Exception('No summaries available');
      }

      // Generate cumulative summary
      final chunkSummaryTexts = allChunkSummaries.map((c) => c.summaryText).toList();
      final cumulativeSummary = await _generateCumulativeSummary(
        chunkSummaryTexts,
        book.title,
      );

      // Save to cache (reuse existing cache variable to preserve tracking fields)
      final newCache = BookSummaryCache(
        bookId: book.id,
        lastProcessedChunkIndex: currentChunkIndex,
        cumulativeSummary: cumulativeSummary,
        lastUpdated: DateTime.now(),
        lastSummaryViewChunkIndex: cache?.lastSummaryViewChunkIndex,
        lastReadingStopChunkIndex: cache?.lastReadingStopChunkIndex,
        lastReadingStopTimestamp: cache?.lastReadingStopTimestamp,
        previousReadingStopChunkIndex: cache?.previousReadingStopChunkIndex,
        previousReadingStopTimestamp: cache?.previousReadingStopTimestamp,
        summarySinceLastTime: cache?.summarySinceLastTime,
        summarySinceLastTimeChunkIndex: cache?.summarySinceLastTimeChunkIndex,
      );

      await _dbService.saveSummaryCache(newCache);

      return cumulativeSummary;
    } catch (e) {
      debugPrint('Error generating summary: $e');
      rethrow;
    }
  }

  /// Parse chapters from EPUB book
  List<Chapter> _parseChapters(EpubBook epubBook) {
    final chapters = <Chapter>[];

    try {
      final epubChapters = epubBook.Chapters;
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

    return chapters;
  }

  /// Get summary since last time the user read
  /// Returns: concise beginning summary + "Since last time:" + new content summary
  Future<String> getSummarySinceLastTime(
    Book book,
    ReadingProgress progress,
  ) async {
    try {
      // Load EPUB to get chapters
      final epub = await _bookService.loadEpubBook(book.filePath);
      final chapters = _parseChapters(epub);

      if (chapters.isEmpty) {
        throw Exception('No chapters found in book');
      }

      final currentChunkIndex = progress.currentChapterIndex;
      
      // Get cache to find reading stop positions
      final cache = await _dbService.getSummaryCache(book.id);
      final lastReadingStopIndex = cache?.lastReadingStopChunkIndex;
      final lastReadingStopTimestamp = cache?.lastReadingStopTimestamp;
      final previousReadingStopIndex = cache?.previousReadingStopChunkIndex;
      final previousReadingStopTimestamp = cache?.previousReadingStopTimestamp;
      
      // Check if we have a cached "since last time" summary that's still valid
      // It's valid if:
      // 1. It exists
      // 2. The reading positions haven't changed (currentChunkIndex == summarySinceLastTimeChunkIndex)
      // 3. The reading stop positions haven't changed
      if (cache != null && 
          cache.summarySinceLastTime != null && 
          cache.summarySinceLastTimeChunkIndex == currentChunkIndex &&
          cache.lastReadingStopChunkIndex == lastReadingStopIndex &&
          cache.previousReadingStopChunkIndex == previousReadingStopIndex) {
        // Return cached summary if it's still valid
        debugPrint('Returning cached "since last time" summary');
        return cache.summarySinceLastTime!;
      }
      
      // Determine the start of "since last time" section:
      // It should be from previousReadingStopIndex to lastReadingStopIndex
      // (the last completed reading session)
      final sessionStartIndex = previousReadingStopIndex ?? 0;
      final sessionEndIndex = lastReadingStopIndex;
      
      // If no reading stops recorded, or user hasn't completed a session yet
      if (lastReadingStopIndex == null || lastReadingStopIndex < 0 || 
          sessionEndIndex == null || sessionEndIndex >= currentChunkIndex) {
        // First reading session or no new content - return concise beginning + empty "Since last time"
        final allChunks = await _dbService.getSummaryChunks(book.id, currentChunkIndex);
        if (allChunks.isEmpty) {
          // Format timestamp if available (even for first session)
          String timestampText = '';
          if (lastReadingStopTimestamp != null) {
            timestampText = _formatTimestamp(lastReadingStopTimestamp);
          }
          final sinceLastTimeHeader = timestampText.isNotEmpty
              ? 'Since last time ($timestampText):'
              : 'Since last time:';
          return 'Beginning of story.\n\n$sinceLastTimeHeader';
        }
        
        // Ensure all chunks are processed
        final lastProcessedIndex = await _dbService.getLastProcessedChunkIndex(book.id);
        for (int i = lastProcessedIndex + 1; i <= currentChunkIndex; i++) {
          if (i >= chapters.length) break;
          final chapter = chapters[i];
          final htmlText = chapter.htmlContent;
          final plainText = _extractTextFromHtml(htmlText);
          if (plainText.isEmpty) continue;
          
          final textChunks = _splitTextIntoChunks(plainText, _maxTokensPerChunk);
          String combinedSummary = '';
          for (int j = 0; j < textChunks.length; j++) {
            final chunkText = textChunks[j];
            final chunkTitle = (j == 0) ? chapter.title : null;
            final summary = await _generateChunkSummary(chunkText, chunkTitle);
            if (j == 0) {
              combinedSummary = summary;
            } else {
              combinedSummary = '$combinedSummary\n\n$summary';
            }
          }
          
          final tokenCount = _estimateTokenCount(plainText);
          final summaryChunk = BookSummaryChunk(
            bookId: book.id,
            chunkIndex: i,
            chunkType: ChunkType.chapter,
            summaryText: combinedSummary,
            tokenCount: tokenCount,
            createdAt: DateTime.now(),
          );
          await _dbService.saveSummaryChunk(summaryChunk);
        }
        
        final allProcessedChunks = await _dbService.getSummaryChunks(book.id, currentChunkIndex);
        if (allProcessedChunks.isNotEmpty) {
          final beginningSummary = await _generateCumulativeSummary(
            allProcessedChunks.map((c) => c.summaryText).toList(),
            book.title,
          );
          final conciseBeginning = await _generateConciseSummary(beginningSummary, book.title);
          
          // Format timestamp if available
          String timestampText = '';
          if (lastReadingStopTimestamp != null) {
            timestampText = _formatTimestamp(lastReadingStopTimestamp);
          }
          final sinceLastTimeHeader = timestampText.isNotEmpty
              ? 'Since last time ($timestampText):'
              : 'Since last time:';
          return '$conciseBeginning\n\n$sinceLastTimeHeader';
        }
        
        // Format timestamp if available
        String timestampText = '';
        if (lastReadingStopTimestamp != null) {
          timestampText = _formatTimestamp(lastReadingStopTimestamp);
        }
        final sinceLastTimeHeader = timestampText.isNotEmpty
            ? 'Since last time ($timestampText):'
            : 'Since last time:';
        return 'Beginning of story.\n\n$sinceLastTimeHeader';
      }
      
      // Get concise beginning summary (from content up to sessionStartIndex)
      // This is the content before the "since last time" session
      String conciseBeginning;
      
      // Ensure chunks up to sessionStartIndex are processed for the beginning summary
      final lastProcessedIndex = await _dbService.getLastProcessedChunkIndex(book.id);
      for (int i = lastProcessedIndex + 1; i <= sessionStartIndex; i++) {
        if (i >= chapters.length) break;
        final chapter = chapters[i];
        final htmlText = chapter.htmlContent;
        final plainText = _extractTextFromHtml(htmlText);
        if (plainText.isEmpty) continue;
        
        final textChunks = _splitTextIntoChunks(plainText, _maxTokensPerChunk);
        String combinedSummary = '';
        for (int j = 0; j < textChunks.length; j++) {
          final chunkText = textChunks[j];
          final chunkTitle = (j == 0) ? chapter.title : null;
          final summary = await _generateChunkSummary(chunkText, chunkTitle);
          if (j == 0) {
            combinedSummary = summary;
          } else {
            combinedSummary = '$combinedSummary\n\n$summary';
          }
        }
        
        final tokenCount = _estimateTokenCount(plainText);
        final summaryChunk = BookSummaryChunk(
          bookId: book.id,
          chunkIndex: i,
          chunkType: ChunkType.chapter,
          summaryText: combinedSummary,
          tokenCount: tokenCount,
          createdAt: DateTime.now(),
        );
        await _dbService.saveSummaryChunk(summaryChunk);
      }
      
      // Get chunks up to sessionStartIndex for concise beginning
      final beginningChunks = await _dbService.getSummaryChunks(book.id, sessionStartIndex);
      if (beginningChunks.isNotEmpty) {
          final beginningSummary = await _generateCumulativeSummary(
            beginningChunks.map((c) => c.summaryText).toList(),
            book.title,
          );
          conciseBeginning = await _generateConciseSummary(beginningSummary, book.title);
      } else {
        conciseBeginning = 'Beginning of story.';
      }

      // Process chunks from sessionStartIndex + 1 to sessionEndIndex (the "since last time" session)
      // First, ensure all chunks in this range are processed
      final lastProcessedIndex2 = await _dbService.getLastProcessedChunkIndex(book.id);
      final startIndex = (lastProcessedIndex2 + 1 > sessionStartIndex + 1) 
          ? lastProcessedIndex2 + 1 
          : sessionStartIndex + 1;
      
      for (int i = startIndex; i <= sessionEndIndex; i++) {
        if (i >= chapters.length) break;

        final chapter = chapters[i];
        final htmlText = chapter.htmlContent;
        final plainText = _extractTextFromHtml(htmlText);
        
        if (plainText.isEmpty) continue;

        // Check if text is too large and needs splitting
        final textChunks = _splitTextIntoChunks(plainText, _maxTokensPerChunk);
        
        String combinedSummary = '';
        for (int j = 0; j < textChunks.length; j++) {
          final chunkText = textChunks[j];
          final chunkTitle = (j == 0) ? chapter.title : null;
          final summary = await _generateChunkSummary(chunkText, chunkTitle);
          if (j == 0) {
            combinedSummary = summary;
          } else {
            combinedSummary = '$combinedSummary\n\n$summary';
          }
        }

        // Save chunk summary
        final tokenCount = _estimateTokenCount(plainText);
        final summaryChunk = BookSummaryChunk(
          bookId: book.id,
          chunkIndex: i,
          chunkType: ChunkType.chapter,
          summaryText: combinedSummary,
          tokenCount: tokenCount,
          createdAt: DateTime.now(),
        );

        await _dbService.saveSummaryChunk(summaryChunk);
      }

      // Get summaries for "since last time" session: from sessionStartIndex + 1 to sessionEndIndex
      final allChunks = await _dbService.getSummaryChunks(book.id, sessionEndIndex);
      final sessionChunks = allChunks.where((c) => 
        c.chunkIndex > sessionStartIndex && c.chunkIndex <= sessionEndIndex
      ).toList();
      
      if (sessionChunks.isEmpty) {
        // No content in the session to summarize
        // Format timestamp if available
        String timestampText = '';
        if (lastReadingStopTimestamp != null) {
          timestampText = _formatTimestamp(lastReadingStopTimestamp);
        }
        final sinceLastTimeHeader = timestampText.isNotEmpty
            ? 'Since last time ($timestampText):'
            : 'Since last time:';
        return '$conciseBeginning\n\n$sinceLastTimeHeader';
      }

      // Generate summary of the last reading session
      final sessionChunkSummaries = sessionChunks.map((c) => c.summaryText).toList();
      final sessionSummary = await _generateCumulativeSummary(
        sessionChunkSummaries,
        book.title,
      );

      // Format timestamp for display
      // The "since last time" section shows content from previousReadingStopIndex to lastReadingStopIndex
      // The timestamp should be when that session ended (lastReadingStopTimestamp)
      String timestampText = '';
      // Use lastReadingStopTimestamp - this is when the session we're showing ended
      if (lastReadingStopTimestamp != null) {
        try {
          timestampText = _formatTimestamp(lastReadingStopTimestamp);
          debugPrint('Formatted timestamp: $timestampText');
        } catch (e) {
          debugPrint('Error formatting timestamp: $e');
        }
      } else {
        debugPrint('Warning: lastReadingStopTimestamp is null. lastReadingStopIndex=$lastReadingStopIndex, previousReadingStopIndex=$previousReadingStopIndex');
      }

      // Combine: concise beginning + "Since last time:" + session summary
      final sinceLastTimeHeader = timestampText.isNotEmpty
          ? 'Since last time ($timestampText):'
          : 'Since last time:';
      final fullSummary = '$conciseBeginning\n\n$sinceLastTimeHeader\n\n$sessionSummary';
      
      // Cache the generated summary
      if (cache != null) {
        final updatedCache = cache.copyWith(
          summarySinceLastTime: fullSummary,
          summarySinceLastTimeChunkIndex: currentChunkIndex,
        );
        await _dbService.saveSummaryCache(updatedCache);
      } else {
        // Create new cache with the summary
        final newCache = BookSummaryCache(
          bookId: book.id,
          lastProcessedChunkIndex: currentChunkIndex,
          cumulativeSummary: '',
          lastUpdated: DateTime.now(),
          lastReadingStopChunkIndex: lastReadingStopIndex,
          lastReadingStopTimestamp: lastReadingStopTimestamp,
          previousReadingStopChunkIndex: previousReadingStopIndex,
          previousReadingStopTimestamp: previousReadingStopTimestamp,
          summarySinceLastTime: fullSummary,
          summarySinceLastTimeChunkIndex: currentChunkIndex,
        );
        await _dbService.saveSummaryCache(newCache);
      }
      
      return fullSummary;
    } catch (e) {
      debugPrint('Error generating summary since last time: $e');
      rethrow;
    }
  }

  /// Update the last summary view position
  Future<void> updateLastSummaryView(String bookId, int chunkIndex) async {
    await _dbService.updateLastSummaryView(bookId, chunkIndex);
  }

  /// Update the last reading stop position (when user stops reading)
  Future<void> updateLastReadingStop(String bookId, int chunkIndex) async {
    await _dbService.updateLastReadingStop(bookId, chunkIndex);
  }

  /// Format timestamp for display (e.g., "Nov. 4th, 2:05pm" or "4 nov., 14:05")
  String _formatTimestamp(DateTime timestamp) {
    try {
      final locale = Intl.systemLocale;
      
      if (locale.startsWith('fr')) {
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
      // Fallback to simple format if formatting fails
      debugPrint('Error formatting timestamp: $e');
      return DateFormat('MMM d, h:mma').format(timestamp).toLowerCase();
    }
  }

  /// Generate characters summary - list of characters with descriptions and relationships
  Future<String> getCharactersSummary(
    Book book,
    ReadingProgress progress,
  ) async {
    try {
      // Load EPUB to get chapters
      final epub = await _bookService.loadEpubBook(book.filePath);
      final chapters = _parseChapters(epub);

      if (chapters.isEmpty) {
        throw Exception('No chapters found in book');
      }

      final currentChunkIndex = progress.currentChapterIndex;
      
      // Check if we have a cached characters summary that's still valid
      final cache = await _dbService.getSummaryCache(book.id);
      if (cache != null && 
          cache.charactersSummary != null && 
          cache.charactersSummaryChunkIndex == currentChunkIndex) {
        // Return cached summary if it's still valid
        debugPrint('Returning cached characters summary');
        return cache.charactersSummary!;
      }

      // Get existing chunk summaries (reuse from regular summaries)
      final existingChunks = await _dbService.getSummaryChunks(book.id, currentChunkIndex);
      final lastProcessedIndex = await _dbService.getLastProcessedChunkIndex(book.id);

      // Process new chunks if needed (same as regular summary processing)
      for (int i = lastProcessedIndex + 1; i <= currentChunkIndex; i++) {
        if (i >= chapters.length) break;

        final chapter = chapters[i];
        final htmlText = chapter.htmlContent;
        final plainText = _extractTextFromHtml(htmlText);
        
        if (plainText.isEmpty) continue;

        // Check if text is too large and needs splitting
        final textChunks = _splitTextIntoChunks(plainText, _maxTokensPerChunk);
        
        String combinedSummary = '';
        for (int j = 0; j < textChunks.length; j++) {
          final chunkText = textChunks[j];
          // Only use chapter title for the first chunk
          final chunkTitle = (j == 0) ? chapter.title : null;
          final summary = await _generateChunkSummary(chunkText, chunkTitle);
          if (j == 0) {
            combinedSummary = summary;
          } else {
            // Combine summaries if chapter was split
            combinedSummary = '$combinedSummary\n\n$summary';
          }
        }

        // Save chunk summary (reuse same chunks as regular summaries)
        final tokenCount = _estimateTokenCount(plainText);
        final summaryChunk = BookSummaryChunk(
          bookId: book.id,
          chunkIndex: i,
          chunkType: ChunkType.chapter,
          summaryText: combinedSummary,
          tokenCount: tokenCount,
          createdAt: DateTime.now(),
        );

        await _dbService.saveSummaryChunk(summaryChunk);
      }

      // Get all chunk summaries up to current position
      final allChunkSummaries = await _dbService.getSummaryChunks(book.id, currentChunkIndex);
      
      if (allChunkSummaries.isEmpty) {
        throw Exception('No summaries available');
      }

      // Generate characters summary from chunk summaries
      final chunkSummaryTexts = allChunkSummaries.map((c) => c.summaryText).toList();
      final charactersSummary = await _generateCharactersSummary(
        chunkSummaryTexts,
        book.title,
      );

      // Cache the generated characters summary
      if (cache != null) {
        final updatedCache = cache.copyWith(
          charactersSummary: charactersSummary,
          charactersSummaryChunkIndex: currentChunkIndex,
        );
        await _dbService.saveSummaryCache(updatedCache);
      } else {
        // Create new cache with the characters summary
        final newCache = BookSummaryCache(
          bookId: book.id,
          lastProcessedChunkIndex: currentChunkIndex,
          cumulativeSummary: '',
          lastUpdated: DateTime.now(),
          charactersSummary: charactersSummary,
          charactersSummaryChunkIndex: currentChunkIndex,
        );
        await _dbService.saveSummaryCache(newCache);
      }

      return charactersSummary;
    } catch (e) {
      debugPrint('Error generating characters summary: $e');
      rethrow;
    }
  }

  /// Generate characters summary from chunk summaries
  Future<String> _generateCharactersSummary(
    List<String> chunkSummaries,
    String bookTitle,
  ) async {
    final apiKey = await _getStoredApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('OpenAI API key not configured. Please set it in settings.');
    }

    final combinedSummaries = chunkSummaries
        .asMap()
        .entries
        .map((e) => 'Chapter ${e.key + 1} Summary:\n${e.value}')
        .join('\n\n');

    final languageInstruction = _getLanguageInstruction();
    final prompt = '''$languageInstruction

You are analyzing the characters in a book. Based on the following chapter summaries, create a comprehensive list of all characters that appear in the story. For each character, provide:

1. A summary of who they are (their identity, background, role)
2. What they have done in the story so far (key actions and plot involvement)
3. The nature of their relationships with other characters (family, friends, enemies, allies, etc.)

Format the output as a structured list. For each character, use a clear heading with their name, followed by their description and relationships.

Book Title: $bookTitle

Chapter Summaries:
$combinedSummaries

Characters Summary:''';

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.3,
          'max_tokens': 3000, // Characters summary can be longer
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Track API costs
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final promptTokens = usage['prompt_tokens'] as int? ?? 0;
          final completionTokens = usage['completion_tokens'] as int? ?? 0;
          await _costService.addCost(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
          );
        }
        
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null && content.isNotEmpty) {
          return content.trim();
        } else {
          throw Exception('Empty response from OpenAI API');
        }
      } else {
        final errorData = jsonDecode(response.body) as Map<String, dynamic>;
        final errorMessage = errorData['error']?['message'] ?? 'Unknown error';
        throw Exception('OpenAI API error: $errorMessage');
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to generate characters summary: $e');
    }
  }

  /// Delete all summaries for a book
  Future<void> deleteBookSummaries(String bookId) async {
    await _dbService.deleteBookSummaries(bookId);
  }
}
