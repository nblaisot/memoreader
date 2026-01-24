import 'package:flutter/foundation.dart';
import '../services/rag_database_service.dart';
import '../services/summary_service.dart';

/// Service for generating summaries of the latest events in a book
class LatestEventsService {
  final RagDatabaseService _databaseService;

  LatestEventsService({RagDatabaseService? databaseService})
      : _databaseService = databaseService ?? RagDatabaseService();

  /// Generate a summary of the latest events from the last N chunks read
  /// 
  /// [bookId] - ID of the book
  /// [currentCharPosition] - Current character position in the book
  /// [summaryService] - LLM service for generating the summary
  /// [numChunks] - Number of recent chunks to summarize (default: 10)
  Future<String> generateLatestEventsSummary({
    required String bookId,
    required int currentCharPosition,
    required SummaryService summaryService,
    int numChunks = 10,
  }) async {
    if (kDebugMode) {
      debugPrint('[LatestEvents] Generating summary for book $bookId at position $currentCharPosition');
    }

    // Get last N chunks up to current position
    final chunks = await _databaseService.getLastNChunksUpToPosition(
      bookId,
      currentCharPosition,
      numChunks,
    );

    if (chunks.isEmpty) {
      throw Exception('No chunks available for this position. You may need to read more content first.');
    }

    if (kDebugMode) {
      debugPrint('[LatestEvents] Retrieved ${chunks.length} chunks for summary');
    }

    // Concatenate chunk texts in chronological order
    final context = chunks.asMap().entries.map((entry) {
      final index = entry.key + 1;
      final chunk = entry.value;
      return 'Excerpt $index:\n${chunk.text}\n';
    }).join('\n---\n\n');

    // Build prompt for LLM
    final prompt = '''You are a helpful assistant that summarizes recent events from a book.

Here are excerpts from the book showing the latest events the reader has read:

$context

Task: Write a concise summary of the latest events happening in the attached text. Focus on the main actions, developments, and plot points. Keep the summary engaging and easy to understand.

Summary:''';

    // Generate summary using the LLM service
    final language = 'en'; // Default language for internal prompt
    final summary = await summaryService.generateSummary(prompt, language);

    if (kDebugMode) {
      debugPrint('[LatestEvents] Summary generated successfully');
    }

    return summary;
  }

  /// Check if there are enough chunks available for a summary
  /// 
  /// [bookId] - ID of the book
  /// [currentCharPosition] - Current character position in the book
  /// [minChunks] - Minimum number of chunks required (default: 1)
  Future<bool> hasEnoughChunks({
    required String bookId,
    required int currentCharPosition,
    int minChunks = 1,
  }) async {
    final chunks = await _databaseService.getLastNChunksUpToPosition(
      bookId,
      currentCharPosition,
      minChunks,
    );
    return chunks.length >= minChunks;
  }
}
