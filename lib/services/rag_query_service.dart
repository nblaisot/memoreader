import 'dart:convert';
import 'dart:async';
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
import '../services/ai_model_registry.dart';
import '../services/openai_summary_service.dart';
import '../services/mistral_summary_service.dart';
import '../services/codex_summary_service.dart';
import '../services/rag_chunking_service.dart';
import '../services/rag_indexing_service.dart';
import '../services/rag_streaming.dart';
import '../services/book_service.dart';

class RagChatTurn {
  const RagChatTurn(
    this.question,
    this.answer,
    this.sources, {
    this.usedCompatibilityFallback = false,
  });
  final String question;
  final String answer;
  final List<RagChunk> sources;
  final bool usedCompatibilityFallback;
}

class RagCancellationToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw const RagCancelledException();
  }
}

class RagCancelledException implements Exception {
  const RagCancelledException();
}

/// Result of a RAG query
class RagQueryResult {
  final String answer;
  final List<RagChunk> sourceChunks;
  final double? relevanceScore;
  final bool insufficientEvidence;
  final bool usedCompatibilityFallback;

  RagQueryResult({
    required this.answer,
    required this.sourceChunks,
    this.relevanceScore,
    this.insufficientEvidence = false,
    this.usedCompatibilityFallback = false,
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
    final candidates = onlyReadSoFar
        ? maxCharPosition != null && maxCharPosition > 0
              ? await _databaseService.getChunksUpToPosition(
                  bookId,
                  maxCharPosition,
                )
              : <RagChunk>[]
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
              summaryService: _plannerService(summaryService)!,
              language: language,
            )
          : null,
    );
    final topChunks = retrieval.chunks;

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
    List<RagChatTurn> history = const [],
    void Function(int round)? onRetrievalRound,
    RagCancellationToken? cancellationToken,
    void Function(String delta)? onAnswerDelta,
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
    final localBooks = {
      for (final book in await BookService().getAllBooks()) book.id: book,
    };
    for (final bookId in bookIds) {
      final book = localBooks[bookId];
      if (book == null || !await RagIndexingService.hasLocalBookFile(book)) {
        continue;
      }
      var status = await _databaseService.getIndexStatus(bookId);
      if (status?.chunkingVersion != RagChunkingService.chunkingVersion ||
          status?.indexVersion != RagDatabaseService.indexVersion) {
        onRetrievalRound?.call(0);
        await RagIndexingService()
            .startIndexing(bookId)
            .firstWhere((progress) => progress.isComplete)
            .timeout(const Duration(minutes: 5));
        cancellationToken?.check();
        status = await _databaseService.getIndexStatus(bookId);
      }
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

    // Load only content the reader is allowed to see. A missing read position
    // grants no access when the spoiler boundary is active.
    List<RagChunk> allCandidates;
    if (onlyReadSoFar) {
      // Load per-book chunks respecting read positions
      allCandidates = [];
      for (final bookId in indexedBookIds) {
        final maxPos = bookReadPositions[bookId];
        final chunks = maxPos != null && maxPos > 0
            ? await _databaseService.getChunksUpToPosition(bookId, maxPos)
            : <RagChunk>[];
        allCandidates.addAll(chunks);
      }
    } else {
      allCandidates = await _databaseService.getChunksForBooks(indexedBookIds);
    }

    if (allCandidates.isEmpty) {
      return RagQueryResult(
        answer: _insufficientEvidenceMessage(language),
        sourceChunks: const [],
        insufficientEvidence: true,
      );
    }

    debugPrint(
      '[RAG] MultiQuery: ${allCandidates.length} candidate chunks from ${indexedBookIds.length} books',
    );

    final effectiveTopK = resolvedTopK > 0 ? resolvedTopK : _defaultTopK;
    final plannerService = _plannerService(summaryService);
    var standaloneQuestion = question;
    var reuseSources = false;
    if (plannerService != null && history.isNotEmpty) {
      try {
        final recent = history.reversed
            .take(6)
            .toList()
            .reversed
            .map((turn) => 'Q: ${turn.question}\nA: ${turn.answer}')
            .join('\n');
        final raw = await plannerService
            .generateSummary(
              'Resolve the latest message into a standalone question. Return JSON only: '
              '{"question":string,"reuse_sources":boolean}. Reuse sources only if the '
              'user asks to explain or rephrase the preceding answer without new facts. '
              'History:\n$recent\nLatest: $question',
              language,
            )
            .timeout(const Duration(seconds: 12));
        final parsed = _parseJson(raw);
        final rewritten = parsed['question'];
        if (rewritten is String &&
            rewritten.trim().isNotEmpty &&
            rewritten.length < 500) {
          standaloneQuestion = rewritten.trim();
        }
        reuseSources = parsed['reuse_sources'] == true;
      } catch (_) {
        /* Preserve the original question. */
      }
    }

    final evidence = <String, RagChunk>{};
    if (reuseSources && history.isNotEmpty) {
      for (final chunk in history.last.sources) {
        if (!indexedBookIds.contains(chunk.bookId)) continue;
        final end = onlyReadSoFar ? bookReadPositions[chunk.bookId] : null;
        if (end != null && chunk.charEnd > end) continue;
        if (onlyReadSoFar && end == null) continue;
        evidence[chunk.chunkId] = chunk;
      }
    }
    var search = reuseSources && evidence.isNotEmpty ? '' : standaloneQuestion;
    var bestDenseScore = 0.0;
    final preferred = <String>[];
    final seenQueries = <String>{};
    final started = DateTime.now();
    Duration remainingTime() =>
        const Duration(seconds: 120) - DateTime.now().difference(started);
    for (var round = 1; round <= 5 && search.isNotEmpty; round++) {
      cancellationToken?.check();
      if (remainingTime() <= Duration.zero) break;
      if (!seenQueries.add(search.toLowerCase().trim())) break;
      onRetrievalRound?.call(round);
      HybridRetrievalResult retrieval;
      try {
        retrieval = await _retriever
            .retrieve(
              question: search,
              bookIds: indexedBookIds,
              candidates: allCandidates,
              embeddingService: embeddingService,
              boundaries: onlyReadSoFar ? bookReadPositions : const {},
              topK: 20,
              planner: round == 1 && history.isEmpty && plannerService != null
                  ? ModelQueryPlanner(
                      summaryService: plannerService,
                      language: language,
                    )
                  : null,
            )
            .timeout(remainingTime());
      } on TimeoutException {
        break;
      }
      cancellationToken?.check();
      if (retrieval.bestDenseScore > bestDenseScore) {
        bestDenseScore = retrieval.bestDenseScore;
      }
      final before = evidence.length;
      for (final chunk in retrieval.chunks) {
        if (evidence.length >= 40) break;
        evidence.putIfAbsent(chunk.chunkId, () => chunk);
      }
      if (round == 5) {
        preferred.insertAll(
          0,
          retrieval.chunks.take(4).map((chunk) => chunk.chunkId),
        );
      }
      if (round == 5 || evidence.length == before || plannerService == null) {
        break;
      }
      try {
        final assessmentCandidates = <String, RagChunk>{
          for (final chunk in retrieval.chunks.take(10)) chunk.chunkId: chunk,
          for (final chunk in evidence.values) chunk.chunkId: chunk,
        }.values.take(20).toList();
        final excerpt = assessmentCandidates
            .asMap()
            .entries
            .map((entry) {
              final text = entry.value.text;
              return '[${entry.key}] ${text.length > 900 ? text.substring(0, 900) : text}';
            })
            .join('\n');
        final raw = await plannerService
            .generateSummary(
              'Assess whether these passages answer the question. Return JSON only: '
              '{"sufficient":boolean,"next_query":string,"selected_indices":[integer]}. '
              'Select up to 8 relevant passages by index. Propose a different, '
              'specific search only if evidence is missing. No outside facts. '
              'Question: $standaloneQuestion\nPassages:\n$excerpt',
              language,
            )
            .timeout(
              remainingTime() < const Duration(seconds: 12)
                  ? remainingTime()
                  : const Duration(seconds: 12),
            );
        final decision = _parseJson(raw);
        final selected = decision['selected_indices'];
        if (selected is List) {
          for (final index in selected.whereType<int>().take(8)) {
            if (index >= 0 && index < assessmentCandidates.length) {
              final id = assessmentCandidates[index].chunkId;
              if (!preferred.contains(id)) preferred.add(id);
            }
          }
        }
        if (decision['sufficient'] == true) break;
        final next = decision['next_query'];
        if (next is! String || next.trim().isEmpty || next.length > 240) break;
        search = next.trim();
      } catch (_) {
        break;
      }
    }
    cancellationToken?.check();
    final topChunks = <RagChunk>[
      for (final id in preferred)
        if (evidence[id] != null) evidence[id]!,
      for (final chunk in evidence.values)
        if (!preferred.contains(chunk.chunkId)) chunk,
    ].take(effectiveTopK).toList();

    if (topChunks.isEmpty) {
      return RagQueryResult(
        answer: _insufficientEvidenceMessage(language),
        sourceChunks: topChunks,
        relevanceScore: bestDenseScore,
        insufficientEvidence: true,
      );
    }

    String answer;
    if (summaryService != null) {
      answer = await _generateMultiBookAnswer(
        question: standaloneQuestion,
        chunks: topChunks,
        bookTitles: bookTitles,
        onlyReadSoFar: onlyReadSoFar,
        summaryService: summaryService,
        language: language,
        history: history,
        cancellationToken: cancellationToken,
        onAnswerDelta: onAnswerDelta,
      );
    } else {
      answer = topChunks
          .map((c) => '(${bookTitles[c.bookId] ?? c.bookId}): ${c.text}')
          .join('\n\n---\n\n');
    }

    return RagQueryResult(
      answer: answer,
      sourceChunks: topChunks,
      relevanceScore: bestDenseScore,
      usedCompatibilityFallback:
          summaryService is CodexSummaryService &&
          summaryService.usedCompatibilityFallback,
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
    List<RagChatTurn> history = const [],
    RagCancellationToken? cancellationToken,
    void Function(String delta)? onAnswerDelta,
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

    final conversation = history.reversed
        .take(6)
        .toList()
        .reversed
        .map((turn) => 'User: ${turn.question}\nAssistant: ${turn.answer}')
        .join('\n\n');
    final prompt = language == 'fr'
        ? '''Tu es un assistant utile qui répond aux questions sur des livres en utilisant UNIQUEMENT les extraits fournis.

${onlyReadSoFar ? 'IMPORTANT : L\'utilisateur n\'a lu qu\'une partie des livres. NE RÉVÈLE PAS de spoilers au-delà de ce qu\'il a lu.' : ''}

Voici des extraits de différents livres (le titre du livre est indiqué entre parenthèses) :

$context

Conversation précédente (contexte conversationnel, pas une preuve du livre) :\n$conversation\n\nQuestion : $question

Fournis une réponse utile basée UNIQUEMENT sur les extraits fournis. Cite chaque affirmation factuelle avec son identifiant, par exemple [S1], ainsi que le titre pertinent. Si les extraits ne contiennent pas assez d'informations, dis-le explicitement. ${onlyReadSoFar ? 'Ne révèle rien au-delà de ce qui est montré dans les extraits.' : ''}'''
        : '''You are a helpful assistant that answers questions about books using ONLY the provided excerpts.

${onlyReadSoFar ? 'IMPORTANT: The user has only read part of the books. DO NOT reveal spoilers beyond what they have read.' : ''}

Here are excerpts from different books (the book title is shown in parentheses):

$context

Earlier conversation (context only, not book evidence):\n$conversation\n\nQuestion: $question

Please answer using ONLY the provided excerpts. Cite every factual claim with its source identifier, for example [S1], and the relevant book title. If the excerpts do not contain enough evidence, say so explicitly. ${onlyReadSoFar ? 'Do not reveal anything beyond what is shown in the excerpts.' : ''}''';

    String answer;
    if (summaryService is RagStreamingService && onAnswerDelta != null) {
      final buffer = StringBuffer();
      await for (final delta
          in (summaryService as RagStreamingService).streamRagAnswer(
            prompt,
            language,
          )) {
        cancellationToken?.check();
        buffer.write(delta);
        onAnswerDelta(delta);
      }
      answer = buffer.toString();
      if (answer.trim().isEmpty) {
        throw const FormatException('Empty answer stream');
      }
    } else {
      answer = await summaryService.generateSummary(prompt, language);
    }
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

  static Map<String, dynamic> _parseJson(String raw) {
    final cleaned = raw
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '');
    final value = jsonDecode(cleaned);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('JSON object expected');
    }
    return value;
  }

  static SummaryService? _plannerService(SummaryService? answerService) {
    if (answerService is OpenAISummaryService) {
      return OpenAISummaryService(
        answerService.apiKey,
        model: AiModelRegistry.openAiPlanner.modelId,
      );
    }
    if (answerService is MistralSummaryService) {
      return MistralSummaryService(
        answerService.apiKey,
        model: AiModelRegistry.mistralPlanner.modelId,
      );
    }
    if (answerService is CodexSummaryService) {
      return CodexSummaryService(model: AiModelRegistry.openAiPlanner.modelId);
    }
    return answerService;
  }
}
