import 'package:flutter/foundation.dart';
import '../services/rag_database_service.dart';
import '../services/summary_service.dart';
import '../models/reading_boundary.dart';
import 'rag_context_builder.dart';

/// Service for generating summaries of the latest events in a book
class LatestEventsService {
  final RagDatabaseService _databaseService;
  final RagContextBuilder _contextBuilder;

  LatestEventsService({
    RagDatabaseService? databaseService,
    RagContextBuilder? contextBuilder,
  }) : _databaseService = databaseService ?? RagDatabaseService(),
       _contextBuilder = contextBuilder ?? const RagContextBuilder();

  /// Generate a summary of the latest events from the last N chunks read
  ///
  /// [bookId] - ID of the book
  /// [currentCharPosition] - Current character position in the book
  /// [summaryService] - LLM service for generating the summary
  /// [language] - Language code ('fr' or 'en') for the prompt and summary
  /// [numChunks] - Number of recent chunks to summarize (default: 10)
  Future<String> generateLatestEventsSummary({
    required String bookId,
    required int currentCharPosition,
    required SummaryService summaryService,
    required String language,
    int numChunks = 100,
  }) async {
    if (kDebugMode) {
      debugPrint(
        '[LatestEvents] Generating summary for book $bookId at position $currentCharPosition',
      );
    }

    // Get last N chunks up to current position
    final candidates = await _databaseService.getLastNChunksUpToPosition(
      bookId,
      currentCharPosition,
      numChunks,
    );
    final chunks = _contextBuilder.recentWindow(
      candidates,
      boundary: ReadingBoundary(lastVisibleExclusive: currentCharPosition),
    );

    if (chunks.isEmpty) {
      throw Exception(
        'No chunks available for this position. You may need to read more content first.',
      );
    }

    if (kDebugMode) {
      debugPrint(
        '[LatestEvents] Retrieved ${chunks.length} chunks for summary',
      );
    }

    // Concatenate chunk texts in chronological order
    final excerptLabel = language == 'fr' ? 'Extrait' : 'Excerpt';
    final context = chunks
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key + 1;
          final chunk = entry.value;
          return '$excerptLabel $index:\n${chunk.text}\n';
        })
        .join('\n---\n\n');

    // Build prompt for LLM based on language
    final prompt = language == 'fr'
        ? '''Tu es un assistant utile qui résume les événements récents d'un livre.

Voici des extraits du livre montrant les derniers événements que le lecteur a lus :

$context

Tâche : Écris un résumé concis des derniers événements qui se produisent dans le texte fourni. Le dernier extrait se termine exactement au dernier caractère vu par le lecteur. N'invente aucune résolution et ne révèle rien après cette limite. Concentre-toi sur les actions principales, les développements et les points de l'intrigue.

Résumé :'''
        : '''You are a helpful assistant that summarizes recent events from a book.

Here are excerpts from the book showing the latest events the reader has read:

$context

Task: Write a concise summary of the latest events happening in the attached text. The final excerpt ends exactly at the last character seen by the reader. Do not invent a resolution or reveal anything after that boundary. Focus on the main actions, developments, and plot points.

Summary:''';

    // Generate summary using the LLM service
    final summary = await summaryService.generateSummary(
      prompt,
      language,
      bookId: '$bookId:latest-events:$currentCharPosition:v2',
    );

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
