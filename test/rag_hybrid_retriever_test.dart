import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/services/rag_database_service.dart';
import 'package:memoreader/services/rag_embedding_service.dart';
import 'package:memoreader/services/rag_hybrid_retriever.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _QueryEmbeddingFake implements EmbeddingService {
  @override
  int get embeddingDimensions => 2;
  @override
  int get maxTokensPerInput => 100;
  @override
  String get modelName => 'fake';
  @override
  String get providerName => 'fake';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<Float32List> embedText(String text) async =>
      Float32List.fromList([1, 0]);
  @override
  Future<List<Float32List>> embedTexts(List<String> texts) async =>
      texts.map((_) => Float32List.fromList([1, 0])).toList();
}

RagChunk _chunk(String id, String text, Float32List embedding, int start) =>
    RagChunk(
      chunkId: id,
      bookId: 'book',
      text: text,
      embedding: embedding,
      embeddingDimension: 2,
      charStart: start,
      charEnd: start + text.length,
      tokenStart: 0,
      tokenEnd: text.length,
      createdAt: DateTime.utc(2026),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await RagDatabaseService().close();
    final file = File(p.join(await getDatabasesPath(), 'rag.db'));
    if (file.existsSync()) file.deleteSync();
  });

  tearDown(() async {
    await RagDatabaseService().clearAll();
    await RagDatabaseService().close();
  });

  test(
    'lexical rank recovers rare exact term missed by dense-only ordering',
    () async {
      final denseFavorite = _chunk(
        'dense',
        'A generic discussion of engines.',
        Float32List.fromList([1, 0]),
        0,
      );
      final lexicalFavorite = _chunk(
        'lexical',
        'The quasar valve is opened by Mira.',
        Float32List.fromList([0, 1]),
        100,
      );
      final db = RagDatabaseService();
      await db.saveChunks([denseFavorite, lexicalFavorite]);

      final result = await RagHybridRetriever(databaseService: db).retrieve(
        question: 'Who opens the quasar valve?',
        bookIds: ['book'],
        candidates: [denseFavorite, lexicalFavorite],
        embeddingService: _QueryEmbeddingFake(),
        topK: 2,
      );

      expect(result.hasLexicalEvidence, isTrue);
      expect(result.chunks.map((chunk) => chunk.chunkId), contains('lexical'));
    },
  );
}
