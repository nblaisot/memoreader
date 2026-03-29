import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/rag_chunk.dart';
import '../models/rag_index_progress.dart';
import '../services/rag_database_service.dart';
import '../services/rag_embedding_service_factory.dart';
import '../services/settings_service.dart';
import '../services/summary_service.dart';

/// Result of a RAG query
class RagQueryResult {
  final String answer;
  final List<RagChunk> sourceChunks;
  final double? relevanceScore;

  RagQueryResult({
    required this.answer,
    required this.sourceChunks,
    this.relevanceScore,
  });
}

/// Service for querying books using RAG
class RagQueryService {
  final RagDatabaseService _databaseService;
  static const int _defaultTopK = 10;

  RagQueryService({RagDatabaseService? databaseService})
      : _databaseService = databaseService ?? RagDatabaseService();

  /// Query a book using RAG
  /// 
  /// [bookId] - ID of the book to query
  /// [question] - User's question
  /// [onlyReadSoFar] - If true, only search in content up to reading position
  /// [maxCharPosition] - Maximum character position (for "read so far" mode)
  /// [summaryService] - LLM service for generating answers
  /// [language] - Language code ('fr' or 'en') for the prompt and answer
  /// [topK] - Number of top chunks to retrieve (default: 10)
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
      throw Exception('Embedding service not available. Please configure API key.');
    }

    // Check if book is indexed
    final indexStatus = await _databaseService.getIndexStatus(bookId);
    if (indexStatus == null || !indexStatus.isComplete) {
      throw Exception(
        'Book is not fully indexed yet. Please wait for indexing to complete.',
      );
    }

    // Check embedding dimension match
    if (indexStatus.embeddingDimension != embeddingService.embeddingDimensions) {
      throw Exception(
        'Embedding dimension mismatch. Book was indexed with ${indexStatus.embeddingDimension} dimensions, '
        'but current service uses ${embeddingService.embeddingDimensions} dimensions.',
      );
    }

    // Generate embedding for question
    final questionEmbedding = await embeddingService.embedText(question);

    // Retrieve candidate chunks
    final candidates = onlyReadSoFar && maxCharPosition != null
        ? await _databaseService.getChunksUpToPosition(bookId, maxCharPosition)
        : await _databaseService.getChunks(bookId);

    if (candidates.isEmpty) {
      throw Exception('No chunks found for this book.');
    }

    debugPrint('[RAG] Query: Retrieved ${candidates.length} candidate chunks');
    debugPrint('[RAG] Query: Question embedding dimension: ${questionEmbedding.length}');

    // Compute cosine similarity for each chunk
    final scoredChunks = <({RagChunk chunk, double score})>[];
    int skippedCount = 0;
    for (final chunk in candidates) {
      if (chunk.embedding.length != questionEmbedding.length) {
        skippedCount++;
        if (skippedCount <= 5) {
          debugPrint('[RAG] Query: Skipping chunk ${chunk.chunkId} - embedding dimension mismatch: chunk=${chunk.embedding.length}, question=${questionEmbedding.length}, chunkDimension=${chunk.embeddingDimension}');
        }
        continue; // Skip chunks with mismatched dimensions
      }
      final similarity = _cosineSimilarity(questionEmbedding, chunk.embedding);
      scoredChunks.add((chunk: chunk, score: similarity));
    }
    
    if (skippedCount > 0) {
      debugPrint('[RAG] Query: Skipped $skippedCount chunks due to dimension mismatch');
    }
    debugPrint('[RAG] Query: Computed similarity for ${scoredChunks.length} chunks');

    // Sort by similarity (descending)
    scoredChunks.sort((a, b) => b.score.compareTo(a.score));

    // Select top-K chunks
    final topChunks = scoredChunks
        .take(resolvedTopK > 0 ? resolvedTopK : _defaultTopK)
        .map((s) => s.chunk)
        .toList();

    if (topChunks.isEmpty) {
      throw Exception('No relevant chunks found.');
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
      relevanceScore: scoredChunks.isNotEmpty ? scoredChunks.first.score : null,
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
    final context = chunks.asMap().entries.map((entry) {
      final index = entry.key + 1;
      final chunk = entry.value;
      return '$excerptLabel $index:\n${chunk.text}\n';
    }).join('\n---\n\n');

    // Build prompt based on language
    final prompt = language == 'fr'
        ? '''Tu es un assistant utile qui répond aux questions sur un livre en utilisant UNIQUEMENT les extraits fournis.

${onlyReadSoFar ? 'IMPORTANT : L\'utilisateur n\'a lu que jusqu\'à un certain point dans le livre. NE RÉVÈLE PAS de spoilers ou d\'informations au-delà de ce qu\'il a lu. Utilise uniquement les informations des extraits fournis.' : ''}

Voici des extraits du livre :

$context

Question : $question

Fournis une réponse utile basée UNIQUEMENT sur les extraits fournis. ${onlyReadSoFar ? 'Ne mentionne pas et ne révèle rien au-delà de ce qui est montré dans les extraits.' : 'Si les extraits ne contiennent pas assez d\'informations pour répondre à la question, dis-le.'}'''
        : '''You are a helpful assistant that answers questions about a book using ONLY the provided excerpts.

${onlyReadSoFar ? 'IMPORTANT: The user has only read up to a certain point in the book. DO NOT reveal spoilers or information beyond what they have read. Only use information from the provided excerpts.' : ''}

Here are excerpts from the book:

$context

Question: $question

Please provide a helpful answer based ONLY on the provided excerpts. ${onlyReadSoFar ? 'Do not mention or reveal anything beyond what is shown in the excerpts.' : 'If the excerpts do not contain enough information to answer the question, say so.'}''';

    // Generate answer using summary service
    return await summaryService.generateSummary(prompt, language);
  }

  /// Compute cosine similarity between two vectors
  /// 
  /// If vectors are normalized (L2 norm = 1), cosine similarity = dot product
  double _cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have same length');
    }

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    // Avoid division by zero
    if (normA == 0.0 || normB == 0.0) {
      return 0.0;
    }

    // Cosine similarity = dot product / (||a|| * ||b||)
    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
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
      throw Exception('Embedding service not available. Please configure API key.');
    }

    // Filter to only fully indexed books
    final indexedBookIds = <String>[];
    for (final bookId in bookIds) {
      final status = await _databaseService.getIndexStatus(bookId);
      if (status != null && status.isComplete) {
        // Check embedding dimension compatibility
        if (status.embeddingDimension == embeddingService.embeddingDimensions) {
          indexedBookIds.add(bookId);
        }
      }
    }

    if (indexedBookIds.isEmpty) {
      throw Exception('None of the selected books are indexed. Please wait for indexing to complete.');
    }

    // Embed question
    final questionEmbedding = await embeddingService.embedText(question);

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

    debugPrint('[RAG] MultiQuery: ${allCandidates.length} candidate chunks from ${indexedBookIds.length} books');

    // Score chunks
    final scoredChunks = <({RagChunk chunk, double score})>[];
    for (final chunk in allCandidates) {
      if (chunk.embedding.length != questionEmbedding.length) continue;
      final similarity = _cosineSimilarity(questionEmbedding, chunk.embedding);
      scoredChunks.add((chunk: chunk, score: similarity));
    }

    scoredChunks.sort((a, b) => b.score.compareTo(a.score));
    final effectiveTopK = resolvedTopK > 0 ? resolvedTopK : _defaultTopK;
    final topChunks = scoredChunks.take(effectiveTopK).map((s) => s.chunk).toList();

    if (topChunks.isEmpty) {
      throw Exception('No relevant chunks found.');
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
      answer = topChunks.map((c) => '(${bookTitles[c.bookId] ?? c.bookId}): ${c.text}').join('\n\n---\n\n');
    }

    return RagQueryResult(
      answer: answer,
      sourceChunks: topChunks,
      relevanceScore: scoredChunks.isNotEmpty ? scoredChunks.first.score : null,
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
    final context = chunks.asMap().entries.map((entry) {
      final index = entry.key + 1;
      final chunk = entry.value;
      final title = bookTitles[chunk.bookId] ?? chunk.bookId;
      return '$excerptLabel $index ($title):\n${chunk.text}\n';
    }).join('\n---\n\n');

    final prompt = language == 'fr'
        ? '''Tu es un assistant utile qui répond aux questions sur des livres en utilisant UNIQUEMENT les extraits fournis.

${onlyReadSoFar ? 'IMPORTANT : L\'utilisateur n\'a lu qu\'une partie des livres. NE RÉVÈLE PAS de spoilers au-delà de ce qu\'il a lu.' : ''}

Voici des extraits de différents livres (le titre du livre est indiqué entre parenthèses) :

$context

Question : $question

Fournis une réponse utile basée UNIQUEMENT sur les extraits fournis. Cite le(s) titre(s) de livre(s) concerné(s) dans ta réponse. ${onlyReadSoFar ? 'Ne révèle rien au-delà de ce qui est montré dans les extraits.' : 'Si les extraits ne contiennent pas assez d\'informations, dis-le.'}'''
        : '''You are a helpful assistant that answers questions about books using ONLY the provided excerpts.

${onlyReadSoFar ? 'IMPORTANT: The user has only read part of the books. DO NOT reveal spoilers beyond what they have read.' : ''}

Here are excerpts from different books (the book title is shown in parentheses):

$context

Question: $question

Please provide a helpful answer based ONLY on the provided excerpts. Cite the relevant book title(s) in your answer. ${onlyReadSoFar ? 'Do not reveal anything beyond what is shown in the excerpts.' : 'If the excerpts do not contain enough information to answer the question, say so.'}''';

    return await summaryService.generateSummary(prompt, language);
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
}
