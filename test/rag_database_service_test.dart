import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/models/rag_index_progress.dart';
import 'package:memoreader/services/rag_database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

RagChunk _ragSampleChunk({
  required String bookId,
  required String chunkId,
  required int charStart,
  required int charEnd,
}) {
  final emb = Float32List.fromList([1.0, 2.0, 3.0]);
  return RagChunk(
    chunkId: chunkId,
    bookId: bookId,
    text: 'sample text',
    embedding: emb,
    embeddingDimension: emb.length,
    chapterIndex: 0,
    charStart: charStart,
    charEnd: charEnd,
    tokenStart: 0,
    tokenEnd: 3,
    createdAt: DateTime.utc(2025, 6, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final svc = RagDatabaseService();
    await svc.close();
    final dir = await getDatabasesPath();
    final file = File(p.join(dir, 'rag.db'));
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  tearDown(() async {
    await RagDatabaseService().clearAll();
    await RagDatabaseService().close();
  });

  test('saveChunk and getChunks round-trip', () async {
    final db = RagDatabaseService();
    final chunk = _ragSampleChunk(
      bookId: 'b1',
      chunkId: 'c1',
      charStart: 0,
      charEnd: 10,
    );
    await db.saveChunk(chunk);

    final rows = await db.getChunks('b1');
    expect(rows.length, 1);
    expect(rows.single.chunkId, 'c1');
    expect(rows.single.embedding.length, 3);
    expect(rows.single.text, 'sample text');
  });

  test('getIndexStatus and saveIndexStatus', () async {
    final db = RagDatabaseService();
    expect(await db.getIndexStatus('b2'), isNull);

    final progress = RagIndexProgress(
      bookId: 'b2',
      status: RagIndexStatus.indexing,
      totalChunks: 10,
      indexedChunks: 3,
      lastUpdated: DateTime.utc(2025, 1, 1),
      embeddingModel: 'test-model',
      embeddingDimension: 128,
    );
    await db.saveIndexStatus(progress);

    final loaded = await db.getIndexStatus('b2');
    expect(loaded, isNotNull);
    expect(loaded!.status, RagIndexStatus.indexing);
    expect(loaded.totalChunks, 10);
    expect(loaded.indexedChunks, 3);
    expect(loaded.embeddingModel, 'test-model');
  });

  test('clearBook removes chunks and status', () async {
    final db = RagDatabaseService();
    await db.saveChunk(_ragSampleChunk(
      bookId: 'b3',
      chunkId: 'c1',
      charStart: 0,
      charEnd: 5,
    ));
    await db.saveIndexStatus(
      RagIndexProgress(
        bookId: 'b3',
        status: RagIndexStatus.completed,
        totalChunks: 1,
        indexedChunks: 1,
        lastUpdated: DateTime.utc(2025, 1, 1),
        embeddingModel: 'm',
        embeddingDimension: 3,
      ),
    );

    await db.clearBook('b3');
    expect(await db.getChunks('b3'), isEmpty);
    expect(await db.getIndexStatus('b3'), isNull);
  });

  test('chunkExists detects saved chunk', () async {
    final db = RagDatabaseService();
    await db.saveChunk(_ragSampleChunk(
      bookId: 'b4',
      chunkId: 'cx',
      charStart: 100,
      charEnd: 200,
    ));

    expect(await db.chunkExists('b4', 100, 200), isTrue);
    expect(await db.chunkExists('b4', 100, 201), isFalse);
  });
}
