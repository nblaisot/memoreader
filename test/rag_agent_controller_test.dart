import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/models/rag_index_progress.dart';
import 'package:memoreader/services/rag_agent.dart';
import 'package:memoreader/services/query_planner.dart';
import 'package:memoreader/services/rag_query_service.dart';
import 'package:memoreader/services/rag_database_service.dart';
import 'package:memoreader/services/rag_native_database.dart';
import 'package:memoreader/services/rag_embedding_service.dart';

class Embeddings implements EmbeddingService {
  @override
  String get providerName => 'test';
  @override
  String get modelName => 'test';
  @override
  int get embeddingDimensions => 2;
  @override
  int get maxTokensPerInput => 8192;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<Float32List> embedText(String text) async =>
      Float32List.fromList([1, 0]);
  @override
  Future<List<Float32List>> embedTexts(List<String> texts) async => [
    for (final _ in texts) Float32List.fromList([1, 0]),
  ];
}

QueryPlan plan(String term) => QueryPlan(
  originalQuery: term,
  semanticQueries: [],
  lexicalQuery: '"$term"',
  intent: 'factual',
  isComplex: true,
  facets: ['all details'],
);

class Agent implements RagAgent {
  Agent(this.decide);
  final FutureOr<RagEvidenceDecision> Function(int, List<RagChunk>) decide;
  int assessments = 0;
  List<RagChunk> seen = [];
  @override
  Future<QueryPlan> plan(String question, String history) async => QueryPlan(
    originalQuery: question,
    semanticQueries: [],
    lexicalQuery: '"planet0"',
    intent: 'factual',
    isComplex: true,
    facets: ['all details'],
  );
  @override
  Future<RagEvidenceDecision> assess(
    String q,
    List<RagChunk> chunks,
    List<String> facets,
    int round,
  ) async {
    assessments++;
    seen = chunks;
    return decide(round, chunks);
  }
}

RagEvidenceDecision decision(
  List<RagChunk> chunks, {
  bool sufficient = false,
  List<String> drop = const [],
  String next = 'planet1',
}) => RagEvidenceDecision(
  keepIds: chunks
      .where((c) => !drop.contains(c.chunkId))
      .map((c) => c.chunkId)
      .toList(),
  dropIds: drop,
  sufficient: sufficient,
  nextPlan: plan(next),
  expandIds: [],
  gaps: sufficient ? [] : ['missing relation'],
);
RagChunk passage(int i, String text) => RagChunk(
  chunkId: 'p$i',
  bookId: 'book',
  text: text,
  embedding: Float32List.fromList([1, 0]),
  embeddingDimension: 2,
  sectionIndex: i,
  charStart: i * 10000,
  charEnd: i * 10000 + text.length,
  tokenStart: 0,
  tokenEnd: 10,
  createdAt: DateTime.utc(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = RagDatabaseService();
  setUpAll(() async {
    databaseFactory = ragDatabaseFactory;
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('rag-agent-')).path,
    );
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await db.clearAll();
  });
  tearDownAll(() async => db.close());
  Future<void> seed(List<RagChunk> passages) async {
    await db.saveStagedChunks(passages);
    await db.saveIndexStatus(
      RagIndexProgress(
        bookId: 'book',
        status: RagIndexStatus.indexing,
        totalChunks: passages.length,
        indexedChunks: passages.length,
        lastUpdated: DateTime.now(),
        embeddingProvider: 'test',
        embeddingModel: 'test',
        embeddingDimension: 2,
      ),
    );
    await db.activateStagedBook('book');
  }

  Future<RagQueryResult> ask(
    Agent agent, {
    RagCancellationToken? cancellation,
    Duration budget = const Duration(seconds: 90),
    bool read = false,
    Map<String, int?> positions = const {},
  }) =>
      RagQueryService(
        agent: agent,
        embeddingServiceOverride: Embeddings(),
        researchBudget: budget,
      ).queryMultipleBooks(
        bookIds: ['book'],
        bookTitles: {'book': 'Book'},
        bookReadPositions: positions,
        onlyReadSoFar: read,
        question: 'Explain all connections',
        language: 'en',
        cancellationToken: cancellation,
      );

  test(
    'five assessments run; later evidence can enter a previously full pool',
    () async {
      await seed([
        for (var i = 0; i < 5; i++)
          passage(i, 'planet$i has an important clue.'),
      ]);
      final agent = Agent(
        (round, chunks) => decision(chunks, next: 'planet$round'),
      );
      final result = await ask(agent);
      expect(agent.assessments, 5);
      expect(result.diagnostics['rounds'], 5);
      expect(result.sourceChunks.map((c) => c.chunkId), contains('p4'));
      expect(result.unresolvedFacets, isNotEmpty);
    },
  );
  test(
    'a full assessment pool preserves earlier accepted evidence while admitting new discoveries',
    () async {
      await seed([
        for (var i = 0; i < 24; i++)
          passage(i, 'planet0 has accepted fact $i.'),
        passage(24, 'planet1 contains the final connection.'),
      ]);
      final agent = Agent(
        (round, chunks) =>
            decision(chunks, next: 'planet1', sufficient: round == 2),
      );
      final result = await ask(agent);
      expect(result.sourceChunks.length, 25);
      expect(result.sourceChunks.map((c) => c.chunkId), contains('p24'));
    },
  );
  test('discarded passages never return through adjacent expansion', () async {
    await seed([
      passage(0, 'planet0 is irrelevant.'),
      passage(1, 'planet1 is the actual evidence.'),
    ]);
    final agent = Agent(
      (round, chunks) => decision(
        chunks,
        drop: round == 1 ? ['p0'] : [],
        next: 'planet1',
        sufficient: round == 2,
      ),
    );
    final result = await ask(agent);
    expect(result.sourceChunks.map((c) => c.chunkId), ['p1']);
    expect(agent.assessments, 2);
  });
  test(
    'assessment receives the complete passage beyond 900 characters',
    () async {
      await seed([
        passage(0, 'planet0 ${'unrelated ' * 100} crucial final detail'),
      ]);
      final agent = Agent((_, chunks) => decision(chunks, sufficient: true));
      await ask(agent);
      expect(agent.seen.single.text, endsWith('crucial final detail'));
    },
  );
  test(
    'malformed assessment preserves candidates without generating an unverified answer',
    () async {
      await seed([passage(0, 'planet0 evidence.')]);
      final agent = Agent((_, __) => throw const FormatException('bad output'));
      final result = await ask(agent);
      expect(agent.assessments, 1);
      expect(result.diagnostics['degraded'], true);
      expect(result.sourceChunks, isEmpty);
      expect(result.status, 'research_failed');
      expect(result.retryCandidates, isNotEmpty);
    },
  );
  test('missing reading position grants no evidence', () async {
    await seed([passage(0, 'planet0 evidence.')]);
    final agent = Agent((_, chunks) => decision(chunks, sufficient: true));
    final result = await ask(agent, read: true);
    expect(result.insufficientEvidence, true);
    expect(agent.assessments, 0);
  });
  test(
    'crossing passages are clipped before assessment and final context',
    () async {
      await seed([passage(0, 'planet0 visible. SECRET future.')]);
      final agent = Agent((_, chunks) => decision(chunks, sufficient: true));
      final result = await ask(agent, read: true, positions: {'book': 16});
      expect(agent.seen.single.text, isNot(contains('SECRET')));
      expect(result.sourceChunks.every((c) => c.charEnd <= 16), true);
    },
  );
  test(
    'cancellation interrupts planning without waiting for the provider',
    () async {
      await seed([passage(0, 'planet0 evidence.')]);
      final token = RagCancellationToken()..cancel();
      final agent = Agent((_, chunks) => decision(chunks));
      await expectLater(
        ask(agent, cancellation: token),
        throwsA(isA<RagCancelledException>()),
      );
    },
  );
  test(
    'soft deadline lets an active assessment finish before stopping new cycles',
    () async {
      await seed([passage(0, 'planet0 evidence.')]);
      final agent = Agent((_, chunks) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return decision(chunks);
      });
      final result = await ask(agent, budget: const Duration(milliseconds: 10));
      expect(result.diagnostics['researchMs'] as int, greaterThanOrEqualTo(50));
      expect(agent.assessments, 1);
      expect(result.sourceChunks, isNotEmpty);
      expect(result.diagnostics['stopReason'], 'deadline');
    },
  );
  test(
    'an incomplete replacement cannot publish or destroy the active index',
    () async {
      await seed([passage(0, 'planet0 old valid evidence.')]);
      await db.saveIndexStatus(
        RagIndexProgress(
          bookId: 'book',
          status: RagIndexStatus.indexing,
          totalChunks: 2,
          indexedChunks: 1,
          lastUpdated: DateTime.now(),
        ),
      );
      await db.saveStagedChunks([passage(1, 'planet1 partial.')]);
      await expectLater(db.activateStagedBook('book'), throwsStateError);
      expect((await db.getActiveIndexStatus('book'))?.isComplete, true);
      expect((await db.getChunks('book')).single.chunkId, 'p0');
    },
  );
  test(
    'native semantic filters exclude future and foreign hits before top k',
    () async {
      await seed([passage(0, 'visible'), passage(1, 'future')]);
      final hits = await db.searchSemantic(
        vector: Float32List.fromList([1, 0]),
        bookIds: ['book'],
        boundaries: {'book': 7},
        limit: 1,
      );
      expect(hits.single.chunk.chunkId, 'p0');
      expect(hits.single.chunk.embedding, isEmpty);
      expect(
        await db.searchSemantic(
          vector: Float32List.fromList([1, 0]),
          bookIds: ['other'],
          limit: 1,
        ),
        isEmpty,
      );
    },
  );
  test(
    'removing a book clears active readiness and its pending generation',
    () async {
      await seed([passage(0, 'planet0 evidence.')]);
      await db.saveStagedChunks([passage(1, 'planet1 unfinished.')]);
      await db.saveJob('book', {'state': 'ready'});
      await db.clearBook('book');
      expect(await db.getActiveIndexStatus('book'), isNull);
      expect(await db.getJob('book'), isNull);
      expect(await db.getStagedChunkCount('book'), 0);
      expect(await db.getAllIndexedBookIds(), isEmpty);
    },
  );
}
