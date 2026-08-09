import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/rag_chunk.dart';
import '../models/rag_index_progress.dart';
import '../services/rag_database_service.dart';
import '../services/rag_embedding_service_factory.dart';
import '../services/settings_service.dart';
import '../services/summary_service.dart';
import '../services/rag_hybrid_retriever.dart';
import '../services/query_planner.dart';

/// Result of a RAG query
class RagQueryResult {
  final String answer;
  final List<RagChunk> sourceChunks;
  final double? relevanceScore;
  final bool insufficientEvidence;

  RagQueryResult({
    required this.answer,
    required this.sourceChunks,
    this.relevanceScore,
    this.insufficientEvidence = false,
  });
}

/// Service for querying books using RAG
class RagQueryService {
  final RagDatabaseService _databaseService;
  late final RagHybridRetriever _retriever;
  static const int _defaultTopK = 8;

  RagQueryService({RagDatabaseService? databaseService})
    : _databaseService = databaseService ?? RagDatabaseService() {
    _retriever = RagHybridRetriever(databaseService: _databaseService);
  }

  /// Query a book using RAG
  ///
  /// [bookId] - ID of the book to query
  /// [question] - User's question
  /// [onlyReadSoFar] - If true, only search in content up to reading position
  /// [maxCharPosition] - Maximum character position (for "read so far" mode)
  /// [summaryService] - LLM service for generating answers
  /// [language] - Language code ('fr' or 'en') for the prompt and answer
  /// [topK] - Number of top chunks to retrieve (default: 8)
  Future<RagQueryResult> query({
    required String bookId,
    required String question,
    bool onlyReadSoFar = false,
    int? maxCharPosition,
    SummaryService? summaryService,
    required String language,
    int? topK,
  }) async {
    final settingsService = SettingsService();
    final resolvedTopK = topK ?? await settingsService.getRagTopK();

    // Get embedding service
    final prefs = await SharedPreferences.getInstance();
    final embeddingService = await RagEmbeddingServiceFactory.create(prefs);

    if (embeddingService == null) {
      throw Exception(
        await RagEmbeddingServiceFactory.unavailableMessage(prefs),
      );
    }

    // Check if book is indexed
    final indexStatus = await _databaseService.getIndexStatus(bookId);
    if (indexStatus == null || !indexStatus.isComplete) {
      throw Exception(
        'Book is not fully indexed yet. Please wait for indexing to complete.',
      );
    }

    // Check the complete embedding identity. Equal dimensions do not make
    // vectors from different providers/models compatible.
    if (indexStatus.embeddingDimension !=
            embeddingService.embeddingDimensions ||
        indexStatus.embeddingModel != embeddingService.modelName ||
        indexStatus.embeddingProvider != embeddingService.providerName) {
      throw Exception(
        'Embedding index mismatch. Re-index this book with the selected '
        '${embeddingService.providerName}/${embeddingService.modelName} provider.',
      );
    }

    // Retrieve candidate chunks
    final candidates = onlyReadSoFar && maxCharPosition != null
        ? await _databaseService.getChunksUpToPosition(bookId, maxCharPosition)
        : await _databaseService.getChunks(bookId);

    if (candidates.isEmpty) {
      throw Exception('No chunks found for this book.');
    }

    final retrieval = await _retriever.retrieve(
      question: question,
      bookIds: [bookId],
      candidates: candidates,
      embeddingService: embeddingService,
      boundaries: {if (onlyReadSoFar) bookId: maxCharPosition},
      topK: resolvedTopK > 0 ? resolvedTopK : _defaultTopK,
      planner: summaryService != null && _needsModelPlanning(question)
          ? ModelQueryPlanner(
              summaryService: summaryService,
              language: language,
            )
          : null,
    );
    final topChunks = retrieval.chunks;

    if (topChunks.isEmpty) {
      throw Exception('No relevant chunks found.');
    }

    if (!_hasEnoughEvidence(retrieval)) {
      return RagQueryResult(
        answer: _insufficientEvidenceMessage(language),
        sourceChunks: topChunks,
        relevanceScore: retrieval.bestDenseScore,
        insufficientEvidence: true,
      );
    }

    // If summary service is provided, generate answer using LLM
    String answer;
    if (summaryService != null) {
      answer = await _generateAnswer(
        question: question,
        chunks: topChunks,
        onlyReadSoFar: onlyReadSoFar,
        summaryService: summaryService,
        language: language,
      );
    } else {
      // Fallback: just return chunk text
      answer = topChunks.map((c) => c.text).join('\n\n---\n\n');
    }

    return RagQueryResult(
      answer: answer,
      sourceChunks: topChunks,
      relevanceScore: retrieval.bestDenseScore,
    );
  }

  /// Generate answer using LLM with retrieved chunks
  Future<String> _generateAnswer({
    required String question,
    required List<RagChunk> chunks,
    required bool onlyReadSoFar,
    required SummaryService summaryService,
    required String language,
  }) async {
    // Build context from chunks
    final excerptLabel = language == 'fr' ? 'Extrait' : 'Excerpt';
    final context = chunks
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key + 1;
          final chunk = entry.value;
          final sourceId = 'S$index';
          final location = chunk.chapterTitle?.trim().isNotEmpty == true
              ? chunk.chapterTitle!.trim()
              : 'chars ${chunk.charStart}-${chunk.charEnd}';
          return '[$sourceId] $excerptLabel $index ($location):\n${chunk.text}\n';
        })
        .join('\n---\n\n');

    // Build prompt based on language
    final prompt = language == 'fr'
        ? '''Tu es un assistant utile qui répond aux questions sur un livre en utilisant UNIQUEMENT les extraits fournis.

${onlyReadSoFar ? 'IMPORTANT : L\'utilisateur n\'a lu que jusqu\'à un certain point dans le livre. NE RÉVÈLE PAS de spoilers ou d\'informations au-delà de ce qu\'il a lu. Utilise uniquement les informations des extraits fournis.' : ''}

Voici des extraits du livre :

$context

Question : $question

Fournis une réponse utile basée UNIQUEMENT sur les extraits fournis. Cite chaque affirmation factuelle avec son identifiant, par exemple [S1]. Si les extraits ne contiennent pas assez d'informations, dis-le explicitement au lieu de compléter avec tes connaissances. ${onlyReadSoFar ? 'Ne mentionne pas et ne révèle rien au-delà de ce qui est montré dans les extraits.' : ''}'''
        : '''You are a helpful assistant that answers questions about a book using ONLY the provided excerpts.

${onlyReadSoFar ? 'IMPORTANT: The user has only read up to a certain point in the book. DO NOT reveal spoilers or information beyond what they have read. Only use information from the provided excerpts.' : ''}

Here are excerpts from the book:

$context

Question: $question

Please answer using ONLY the provided excerpts. Cite every factual claim with its source identifier, for example [S1]. If the excerpts do not contain enough evidence, say so explicitly instead of filling gaps from prior knowledge. ${onlyReadSoFar ? 'Do not mention or reveal anything beyond what is shown in the excerpts.' : ''}''';

    // Generate answer using summary service
    final answer = await summaryService.generateSummary(prompt, language);
    return _sanitizeCitations(answer, chunks.length);
  }

  /// Query multiple books using RAG
  ///
  /// [bookIds] - IDs of the books to query
  /// [bookTitles] - Map of bookId to book title (for source attribution)
  /// [bookReadPositions] - Map of bookId to max char position (null = no filter)
  /// [onlyReadSoFar] - If true, filter each book's chunks to its read position
  /// [question] - User's question
  /// [summaryService] - LLM service for generating answers
  /// [language] - Language code ('fr' or 'en')
  /// [topK] - Number of top chunks to retrieve
  Future<RagQueryResult> queryMultipleBooks({
    required List<String> bookIds,
    required Map<String, String> bookTitles,
    required Map<String, int?> bookReadPositions,
    bool onlyReadSoFar = false,
    required String question,
    SummaryService? summaryService,
    required String language,
    int? topK,
  }) async {
    final settingsService = SettingsService();
    final resolvedTopK = topK ?? await settingsService.getRagTopK();

    final prefs = await SharedPreferences.getInstance();
    final embeddingService = await RagEmbeddingServiceFactory.create(prefs);

    if (embeddingService == null) {
      throw Exception(
        await RagEmbeddingServiceFactory.unavailableMessage(prefs),
      );
    }

    // Filter to only fully indexed books
    final indexedBookIds = <String>[];
    for (final bookId in bookIds) {
      final status = await _databaseService.getIndexStatus(bookId);
      if (status != null && status.isComplete) {
        if (status.embeddingDimension == embeddingService.embeddingDimensions &&
            status.embeddingModel == embeddingService.modelName &&
            status.embeddingProvider == embeddingService.providerName) {
          indexedBookIds.add(bookId);
        }
      }
    }

    if (indexedBookIds.isEmpty) {
      throw Exception(
        'None of the selected books are indexed. Please wait for indexing to complete.',
      );
    }

    // Load chunks for all indexed books
    List<RagChunk> allCandidates;
    if (onlyReadSoFar) {
      // Load per-book chunks respecting read positions
      allCandidates = [];
      for (final bookId in indexedBookIds) {
        final maxPos = bookReadPositions[bookId];
        final chunks = maxPos != null
            ? await _databaseService.getChunksUpToPosition(bookId, maxPos)
            : await _databaseService.getChunks(bookId);
        allCandidates.addAll(chunks);
      }
    } else {
      allCandidates = await _databaseService.getChunksForBooks(indexedBookIds);
    }

    if (allCandidates.isEmpty) {
      throw Exception('No chunks found for the selected books.');
    }

    debugPrint(
      '[RAG] MultiQuery: ${allCandidates.length} candidate chunks from ${indexedBookIds.length} books',
    );

    final effectiveTopK = resolvedTopK > 0 ? resolvedTopK : _defaultTopK;
    final retrieval = await _retriever.retrieve(
      question: question,
      bookIds: indexedBookIds,
      candidates: allCandidates,
      embeddingService: embeddingService,
      boundaries: onlyReadSoFar ? bookReadPositions : const {},
      topK: effectiveTopK,
      planner: summaryService != null && _needsModelPlanning(question)
          ? ModelQueryPlanner(
              summaryService: summaryService,
              language: language,
            )
          : null,
    );
    final topChunks = retrieval.chunks;

    if (topChunks.isEmpty) {
      throw Exception('No relevant chunks found.');
    }

    if (!_hasEnoughEvidence(retrieval)) {
      return RagQueryResult(
        answer: _insufficientEvidenceMessage(language),
        sourceChunks: topChunks,
        relevanceScore: retrieval.bestDenseScore,
        insufficientEvidence: true,
      );
    }

    String answer;
    if (summaryService != null) {
      answer = await _generateMultiBookAnswer(
        question: question,
        chunks: topChunks,
        bookTitles: bookTitles,
        onlyReadSoFar: onlyReadSoFar,
        summaryService: summaryService,
        language: language,
      );
    } else {
      answer = topChunks
          .map((c) => '(${bookTitles[c.bookId] ?? c.bookId}): ${c.text}')
          .join('\n\n---\n\n');
    }

    return RagQueryResult(
      answer: answer,
      sourceChunks: topChunks,
      relevanceScore: retrieval.bestDenseScore,
    );
  }

  /// Generate answer for multi-book queries with source attribution
  Future<String> _generateMultiBookAnswer({
    required String question,
    required List<RagChunk> chunks,
    required Map<String, String> bookTitles,
    required bool onlyReadSoFar,
    required SummaryService summaryService,
    required String language,
  }) async {
    final excerptLabel = language == 'fr' ? 'Extrait' : 'Excerpt';
    final context = chunks
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key + 1;
          final chunk = entry.value;
          final title = bookTitles[chunk.bookId] ?? chunk.bookId;
          final sourceId = 'S$index';
          final location = chunk.chapterTitle?.trim().isNotEmpty == true
              ? chunk.chapterTitle!.trim()
              : 'chars ${chunk.charStart}-${chunk.charEnd}';
          return '[$sourceId] $excerptLabel $index ($title; $location):\n${chunk.text}\n';
        })
        .join('\n---\n\n');

    final prompt = language == 'fr'
        ? '''Tu es un assistant utile qui répond aux questions sur des livres en utilisant UNIQUEMENT les extraits fournis.

${onlyReadSoFar ? 'IMPORTANT : L\'utilisateur n\'a lu qu\'une partie des livres. NE RÉVÈLE PAS de spoilers au-delà de ce qu\'il a lu.' : ''}

Voici des extraits de différents livres (le titre du livre est indiqué entre parenthèses) :

$context

Question : $question

Fournis une réponse utile basée UNIQUEMENT sur les extraits fournis. Cite chaque affirmation factuelle avec son identifiant, par exemple [S1], ainsi que le titre pertinent. Si les extraits ne contiennent pas assez d'informations, dis-le explicitement. ${onlyReadSoFar ? 'Ne révèle rien au-delà de ce qui est montré dans les extraits.' : ''}'''
        : '''You are a helpful assistant that answers questions about books using ONLY the provided excerpts.

${onlyReadSoFar ? 'IMPORTANT: The user has only read part of the books. DO NOT reveal spoilers beyond what they have read.' : ''}

Here are excerpts from different books (the book title is shown in parentheses):

$context

Question: $question

Please answer using ONLY the provided excerpts. Cite every factual claim with its source identifier, for example [S1], and the relevant book title. If the excerpts do not contain enough evidence, say so explicitly. ${onlyReadSoFar ? 'Do not reveal anything beyond what is shown in the excerpts.' : ''}''';

    final answer = await summaryService.generateSummary(prompt, language);
    return _sanitizeCitations(answer, chunks.length);
  }

  /// Check if a book is indexed
  Future<bool> isBookIndexed(String bookId) async {
    final status = await _databaseService.getIndexStatus(bookId);
    return status != null && status.isComplete;
  }

  /// Get indexing progress for a book
  Future<RagIndexProgress?> getIndexingProgress(String bookId) async {
    return await _databaseService.getIndexStatus(bookId);
  }

  static bool _needsModelPlanning(String question) {
    final lower = question.toLowerCase();
    return question.length > 180 ||
        lower.contains('compare') ||
        lower.contains('difference') ||
        lower.contains('comparez') ||
        lower.contains('différence') ||
        lower.contains('before and after') ||
        lower.contains('avant et après');
  }

  static bool _hasEnoughEvidence(HybridRetrievalResult result) {
    return result.hasLexicalEvidence || result.bestDenseScore >= 0.18;
  }

  static String _insufficientEvidenceMessage(String language) {
    return language == 'fr'
        ? 'Les extraits disponibles ne contiennent pas assez d’éléments pertinents pour répondre de façon fiable.'
        : 'The available excerpts do not contain enough relevant evidence to answer reliably.';
  }

  static String _sanitizeCitations(String answer, int sourceCount) {
    return answer.replaceAllMapped(RegExp(r'\[S(\d+)\]'), (match) {
      final source = int.tryParse(match.group(1)!);
      return source != null && source >= 1 && source <= sourceCount
          ? match.group(0)!
          : '';
    }).trim();
  }
}
