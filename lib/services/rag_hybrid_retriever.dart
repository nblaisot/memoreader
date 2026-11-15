import 'dart:math' as math;
import 'dart:typed_data';
import '../models/rag_chunk.dart';
import '../models/reading_boundary.dart';
import 'query_planner.dart';
import 'rag_generation.dart';
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
    this.diagnostics = const {},
  });
  final Map<String, Object?> diagnostics;
  final List<RagChunk> chunks;
  final double bestDenseScore, bestFusedScore;
  final bool hasLexicalEvidence, degraded;
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
  static final _embeddingCache = <String, Float32List>{};

  Future<HybridRetrievalResult> retrieve({
    required String question,
    required List<String> bookIds,
    List<RagChunk>? candidates,
    required EmbeddingService embeddingService,
    Map<String, int?> boundaries = const {},
    int topK = 24,
    QueryPlanner? planner,
    QueryPlan? queryPlan,
  }) async {
    final plan = queryPlan ?? await (planner ?? _planner).plan(question);
    var degraded = false;
    final lexicalClock = Stopwatch()..start();
    var lexicalMs = 0;
    final lexicalFuture =
        Future.wait(
          plan.lexicalQueries.take(2).map((q) async {
            try {
              return await _database.searchLexical(
                matchQuery: q,
                bookIds: bookIds,
                boundaries: boundaries,
                limit: 40,
              );
            } catch (e) {
              RagTrace.record('retrieval_failure', {
                'stage': 'lexical',
                'kind': e.runtimeType.toString(),
              });
              degraded = true;
              return <RagLexicalHit>[];
            }
          }),
        ).then((hits) {
          lexicalMs = lexicalClock.elapsedMilliseconds;
          return hits;
        });
    final identity =
        '${embeddingService.providerName}:${embeddingService.modelName}:${embeddingService.embeddingDimensions}';
    String key(String q) =>
        '$identity:${q.trim().replaceAll(RegExp(r'\s+'), ' ')}';
    final queries = plan.semanticQueries.take(2).toList();
    final missing = queries
        .where((q) => !_embeddingCache.containsKey(key(q)))
        .toList();
    final embeddingClock = Stopwatch()..start();
    if (missing.isNotEmpty) {
      try {
        final vectors = await embeddingService.embedTexts(missing);
        for (var i = 0; i < missing.length && i < vectors.length; i++) {
          if (vectors[i].length != embeddingService.embeddingDimensions) {
            continue;
          }
          if (_embeddingCache.length >= 128) {
            _embeddingCache.remove(_embeddingCache.keys.first);
          }
          _embeddingCache[key(missing[i])] = vectors[i];
        }
      } catch (e) {
        RagTrace.record('retrieval_failure', {
          'stage': 'embedding',
          'kind': e.runtimeType.toString(),
        });
        degraded = true;
      }
    }
    final embeddingMs = embeddingClock.elapsedMilliseconds;
    final denseClock = Stopwatch()..start();
    final dense = await Future.wait(
      queries.map((q) async {
        final vector = _embeddingCache[key(q)];
        if (vector == null) {
          degraded = true;
          return <RagLexicalHit>[];
        }
        try {
          return await _database.searchSemantic(
            vector: vector,
            bookIds: bookIds,
            boundaries: boundaries,
            limit: 40,
          );
        } catch (e) {
          RagTrace.record('retrieval_failure', {
            'stage': 'semantic',
            'kind': e.runtimeType.toString(),
          });
          degraded = true;
          return <RagLexicalHit>[];
        }
      }),
    );
    final denseMs = denseClock.elapsedMilliseconds;
    final lexical = await lexicalFuture;
    // A crossing vector contains unread text. Only its clipped prefix can
    // contribute lexical evidence. No network re-embedding in a query.
    final terms = RegExp(r'"([^"]+)"')
        .allMatches(plan.lexicalQueries.join(' '))
        .map((m) => m[1]!.toLowerCase())
        .toList();
    for (final book in bookIds) {
      final boundary = boundaries[book];
      if (boundary == null || boundary <= 0) continue;
      try {
        final status = await _database.getActiveIndexStatus(book);
        final prefixes = await _database.prefixVectors(
          book,
          boundary,
          '$identity:${status?.contentHash}:${status?.configHash}',
        );
        for (final c in await _database.crossingPassages(book, boundary)) {
          final prefix = prefixes[c.chunkId];
          if (prefix != null) {
            final scores = queries
                .map((q) => _embeddingCache[key(q)])
                .whereType<Float32List>()
                .map((q) => cosineSimilarity(q, prefix))
                .toList();
            if (scores.isNotEmpty && dense.isNotEmpty) {
              dense.first.add(
                RagLexicalHit(chunk: c, score: scores.reduce(math.max)),
              );
              dense.first.sort((a, b) => b.score.compareTo(a.score));
            }
          }
          if (terms.any((t) => c.text.toLowerCase().contains(t))) {
            lexical.add([RagLexicalHit(chunk: c, score: 0)]);
          }
        }
      } catch (e) {
        degraded = true;
        RagTrace.record('retrieval_failure', {
          'stage': 'boundary_context',
          'kind': e.runtimeType.toString(),
        });
      }
    }
    final byId = <String, RagChunk>{};
    final fused = <String, double>{};
    for (final list in [...dense, ...lexical]) {
      for (var i = 0; i < list.length; i++) {
        final c = list[i].chunk;
        final boundary = boundaries[c.bookId];
        if (!bookIds.contains(c.bookId) ||
            (boundaries.containsKey(c.bookId) && boundary == null)) {
          continue;
        }
        if (boundary != null && c.charEnd > boundary) continue;
        byId[c.chunkId] = c;
        fused.update(
          c.chunkId,
          (s) => s + 1 / (60 + i + 1),
          ifAbsent: () => 1 / (60 + i + 1),
        );
      }
    }
    final ranked = byId.values.toList()
      ..sort((a, b) => fused[b.chunkId]!.compareTo(fused[a.chunkId]!));
    final selected = <RagChunk>[];
    if (plan.intent == 'comparison') {
      for (final book in bookIds) {
        final hit = ranked.where((c) => c.bookId == book).firstOrNull;
        if (hit != null && selected.length < topK) selected.add(hit);
      }
    }
    for (final c in ranked) {
      if (selected.length >= topK) break;
      if (!selected.any((s) => s.chunkId == c.chunkId)) selected.add(c);
    }
    // Preserve rank for assessment; context merging happens only after reranking.
    final safe = <RagChunk>[];
    for (final c in selected) {
      safe.addAll(
        _contextBuilder.clipAndDeduplicate(
          [c],
          boundary: boundaries[c.bookId] == null
              ? null
              : ReadingBoundary(lastVisibleExclusive: boundaries[c.bookId]!),
        ),
      );
    }
    return HybridRetrievalResult(
      chunks: safe,
      bestDenseScore: dense
          .expand((x) => x)
          .fold(0.0, (s, h) => math.max(s, h.score)),
      bestFusedScore: fused.values.fold(0.0, math.max),
      hasLexicalEvidence: lexical.any((l) => l.isNotEmpty),
      plan: plan,
      degraded: degraded,
      diagnostics: {
        'embeddingMs': embeddingMs,
        'denseMs': denseMs,
        'lexicalMs': lexicalMs,
        'embeddingCacheHits': queries.length - missing.length,
        'fusedCandidates': byId.length,
      },
    );
  }

  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) return 0;
    double dot = 0, na = 0, nb = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return na == 0 || nb == 0 ? 0 : dot / math.sqrt(na * nb);
  }
}
