import 'dart:math' as math;
import 'dart:typed_data';

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
  });

  final List<RagChunk> chunks;
  final double bestDenseScore;
  final double bestFusedScore;
  final bool hasLexicalEvidence;
  final QueryPlan plan;
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
    final retrievalInputs = await Future.wait<Object>([
      embeddingService.embedTexts(plan.semanticQueries),
      _database.searchLexical(
        matchQuery: plan.lexicalQuery,
        bookIds: bookIds,
        boundaries: boundaries,
        limit: math.max(50, topK * 6),
      ),
    ]);
    final questionEmbeddings = retrievalInputs[0] as List<Float32List>;
    final lexical = retrievalInputs[1] as List<RagLexicalHit>;
    final dense = <({RagChunk chunk, double score})>[];
    for (final chunk in candidates) {
      if (questionEmbeddings.isEmpty ||
          chunk.embedding.length != questionEmbeddings.first.length) {
        continue;
      }
      dense.add((
        chunk: chunk,
        score: questionEmbeddings
            .map((query) => cosineSimilarity(query, chunk.embedding))
            .reduce((a, b) => math.max(a, b).toDouble()),
      ));
    }
    dense.sort((a, b) => b.score.compareTo(a.score));
    final poolSize = math.max(50, topK * 6);
    final densePool = dense.take(poolSize).toList();

    final byId = <String, RagChunk>{};
    final fused = <String, double>{};
    const rrfK = 60.0;
    for (var i = 0; i < densePool.length; i++) {
      final item = densePool[i];
      byId[item.chunk.chunkId] = item.chunk;
      fused[item.chunk.chunkId] =
          (fused[item.chunk.chunkId] ?? 0) + 1 / (rrfK + i + 1);
    }
    for (var i = 0; i < lexical.length; i++) {
      final item = lexical[i];
      byId[item.chunk.chunkId] = item.chunk;
      fused[item.chunk.chunkId] =
          (fused[item.chunk.chunkId] ?? 0) + 1 / (rrfK + i + 1);
    }

    final normalizedTerms = plan.lexicalQuery
        .replaceAll('"', '')
        .split(RegExp(r'\s+OR\s+'))
        .map((term) => term.trim().toLowerCase())
        .where((term) => term.isNotEmpty)
        .toList();
    for (final entry in byId.entries) {
      final text = entry.value.text.toLowerCase();
      final covered = normalizedTerms.where(text.contains).length;
      if (covered > 0) {
        fused[entry.key] = (fused[entry.key] ?? 0) + 0.002 * covered;
      }
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
      bestDenseScore: dense.isEmpty ? 0 : dense.first.score,
      bestFusedScore: fused.values.isEmpty
          ? 0
          : fused.values.reduce((a, b) => math.max(a, b).toDouble()),
      hasLexicalEvidence: lexical.isNotEmpty,
      plan: plan,
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
}
