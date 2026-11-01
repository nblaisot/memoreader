import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:isolate';

import '../models/rag_chunk.dart';
import '../models/reading_boundary.dart';
import 'query_planner.dart';
import 'rag_context_builder.dart';
import 'rag_database_service.dart';
import 'rag_embedding_service.dart';

class HybridRetrievalResult {
  const HybridRetrievalResult({
    required this.chunks,
    required this.bestDenseScore,
    required this.bestFusedScore,
    required this.hasLexicalEvidence,
    required this.plan,
    required this.degraded,
  });

  final List<RagChunk> chunks;
  final double bestDenseScore;
  final double bestFusedScore;
  final bool hasLexicalEvidence;
  final QueryPlan plan;
  final bool degraded;
}

class RagHybridRetriever {
  RagHybridRetriever({
    required RagDatabaseService databaseService,
    QueryPlanner? planner,
    RagContextBuilder? contextBuilder,
  }) : _database = databaseService,
       _planner = planner ?? const DeterministicQueryPlanner(),
       _contextBuilder = contextBuilder ?? const RagContextBuilder();

  final RagDatabaseService _database;
  final QueryPlanner _planner;
  final RagContextBuilder _contextBuilder;

  Future<HybridRetrievalResult> retrieve({
    required String question,
    required List<String> bookIds,
    required List<RagChunk> candidates,
    required EmbeddingService embeddingService,
    Map<String, int?> boundaries = const {},
    int topK = 8,
    QueryPlanner? planner,
  }) async {
    final plan = await (planner ?? _planner).plan(question);
    final lexicalFuture = _database.searchLexical(
      matchQuery: plan.lexicalQuery,
      bookIds: bookIds,
      boundaries: boundaries,
      limit: math.max(50, topK * 6),
    );
    // Lexical retrieval remains useful when the online embedding endpoint fails.
    final embeddingFuture = embeddingService
        .embedTexts(plan.semanticQueries)
        .catchError((Object _) => <Float32List>[]);
    final lexical = await lexicalFuture;
    final questionEmbeddings = await embeddingFuture;
    final safeCandidates = <RagChunk>[];
    final crossing = <RagChunk>[];
    for (final chunk in candidates) {
      final boundary = boundaries[chunk.bookId];
      if (boundary != null && chunk.charStart >= boundary) continue;
      if (boundary != null && chunk.charEnd > boundary) {
        final visible = chunk.text.substring(0, boundary - chunk.charStart);
        if (visible.trim().isEmpty) continue;
        crossing.add(chunk.copyWith(text: visible, charEnd: boundary));
      } else {
        safeCandidates.add(chunk);
      }
    }
    // Crossing chunks were embedded with unread text. Re-embed their visible
    // prefix before dense ranking; never score a spoiler-bearing vector.
    if (crossing.isNotEmpty && questionEmbeddings.isNotEmpty) {
      try {
        final vectors = await embeddingService.embedTexts(crossing.map((c) => c.text).toList());
        for (var i = 0; i < crossing.length && i < vectors.length; i++) {
          safeCandidates.add(crossing[i].copyWith(embedding: vectors[i]));
        }
      } catch (_) { /* Lexical search can still recover visible prefixes. */ }
    }
    final safeLexical = lexical.where((hit) {
      final boundary = boundaries[hit.chunk.bookId];
      return boundary == null || hit.chunk.charEnd <= boundary;
    }).toList();
    final lexicalTerms = RegExp(r'"([^"]+)"')
        .allMatches(plan.lexicalQuery)
        .map((match) => match.group(1)!.toLowerCase())
        .toList();
    for (final chunk in crossing) {
      if (lexicalTerms.any((term) => chunk.text.toLowerCase().contains(term))) {
        safeLexical.add(RagLexicalHit(chunk: chunk, score: 0));
      }
    }
    final poolSize = math.max(50, topK * 6);
    final densePool = questionEmbeddings.isEmpty
        ? <({RagChunk chunk, double score})>[]
        : await Isolate.run(() => _rankDense(safeCandidates,
            questionEmbeddings, poolSize));

    final byId = <String, RagChunk>{};
    final fused = <String, double>{};
    const rrfK = 60.0;
    for (var i = 0; i < densePool.length; i++) {
      final item = densePool[i];
      byId[item.chunk.chunkId] = item.chunk;
      fused[item.chunk.chunkId] =
          (fused[item.chunk.chunkId] ?? 0) + 1 / (rrfK + i + 1);
    }
    for (var i = 0; i < safeLexical.length; i++) {
      final item = safeLexical[i];
      byId[item.chunk.chunkId] = item.chunk;
      fused[item.chunk.chunkId] =
          (fused[item.chunk.chunkId] ?? 0) + 1 / (rrfK + i + 1);
    }

    final ranked = byId.values.toList()
      ..sort(
        (a, b) => (fused[b.chunkId] ?? 0).compareTo(fused[a.chunkId] ?? 0),
      );
    final selected = <RagChunk>[];
    if (plan.intent == 'comparison' && bookIds.length > 1) {
      for (final bookId in bookIds) {
        RagChunk? bookHit;
        for (final chunk in ranked) {
          if (chunk.bookId == bookId) {
            bookHit = chunk;
            break;
          }
        }
        if (bookHit != null) selected.add(bookHit);
      }
    }
    for (final chunk in ranked) {
      if (selected.length >= topK) break;
      if (!selected.any((item) => item.chunkId == chunk.chunkId)) {
        selected.add(chunk);
      }
    }

    // Enforce each book's boundary after selection and remove true overlap.
    final safe = <RagChunk>[];
    for (final bookId in bookIds) {
      final bookChunks = selected.where((chunk) => chunk.bookId == bookId);
      final boundary = boundaries[bookId];
      safe.addAll(
        _contextBuilder.clipAndDeduplicate(
          bookChunks,
          boundary: boundary == null
              ? null
              : ReadingBoundary(lastVisibleExclusive: boundary),
        ),
      );
    }
    safe.sort((a, b) {
      final book = a.bookId.compareTo(b.bookId);
      return book != 0 ? book : a.charStart.compareTo(b.charStart);
    });

    return HybridRetrievalResult(
      chunks: safe,
      bestDenseScore: densePool.isEmpty ? 0 : densePool.first.score,
      bestFusedScore: fused.values.isEmpty
          ? 0
          : fused.values.reduce((a, b) => math.max(a, b).toDouble()),
      hasLexicalEvidence: safeLexical.isNotEmpty,
      plan: plan,
      degraded: questionEmbeddings.isEmpty,
    );
  }

  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  static List<({RagChunk chunk, double score})> _rankDense(
      List<RagChunk> candidates, List<Float32List> queries, int poolSize) {
    final ranked = <({RagChunk chunk, double score})>[];
    for (final chunk in candidates) {
      if (chunk.embedding.length != queries.first.length) continue;
      ranked.add((chunk: chunk, score: queries
          .map((query) => cosineSimilarity(query, chunk.embedding))
          .reduce((a, b) => math.max(a, b))));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked.take(poolSize).toList();
  }
}
