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
  String text = 'sample text',
}) {
  final emb = Float32List.fromList([1.0, 2.0, 3.0]);
  return RagChunk(
    chunkId: chunkId,
    bookId: bookId,
    text: text,
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
    await db.saveChunk(
      _ragSampleChunk(bookId: 'b3', chunkId: 'c1', charStart: 0, charEnd: 5),
    );
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
    await db.saveChunk(
      _ragSampleChunk(
        bookId: 'b4',
        chunkId: 'cx',
        charStart: 100,
        charEnd: 200,
      ),
    );

    expect(await db.chunkExists('b4', 100, 200), isTrue);
    expect(await db.chunkExists('b4', 100, 201), isFalse);
  });

  test(
    'boundary query includes crossing chunk for later exact clipping',
    () async {
      final db = RagDatabaseService();
      await db.saveChunk(
        _ragSampleChunk(
          bookId: 'boundary',
          chunkId: 'crossing',
          charStart: 10,
          charEnd: 30,
        ),
      );

      final rows = await db.getChunksUpToPosition('boundary', 20);
      expect(rows.map((row) => row.chunkId), contains('crossing'));
    },
  );

  test(
    'local full-text search finds exact rare terms and respects boundary',
    () async {
      final db = RagDatabaseService();
      await db.saveChunks([
        _ragSampleChunk(
          bookId: 'fts',
          chunkId: 'early',
          charStart: 0,
          charEnd: 25,
          text: 'The quasar engine started quietly.',
        ),
        _ragSampleChunk(
          bookId: 'fts',
          chunkId: 'future',
          charStart: 30,
          charEnd: 60,
          text: 'A second quasar appeared later.',
        ),
      ]);

      final hits = await db.searchLexical(
        matchQuery: '"quasar"',
        bookIds: ['fts'],
        boundaries: {'fts': 20},
      );
      expect(hits.map((hit) => hit.chunk.chunkId), ['early']);
    },
  );

  test('partial progress updates preserve the index manifest', () async {
    final db = RagDatabaseService();
    await db.saveIndexStatus(
      RagIndexProgress(
        bookId: 'manifest',
        status: RagIndexStatus.indexing,
        totalChunks: 2,
        indexedChunks: 0,
        lastUpdated: DateTime.utc(2026),
        embeddingProvider: 'OpenAI',
        embeddingModel: 'text-embedding-3-small',
        embeddingDimension: 1536,
        contentHash: 'content',
        extractionVersion: 1,
        chunkingVersion: 2,
        configHash: 'config',
        indexVersion: 2,
      ),
    );
    await db.saveIndexStatus(
      RagIndexProgress(
        bookId: 'manifest',
        status: RagIndexStatus.indexing,
        totalChunks: 2,
        indexedChunks: 1,
        lastUpdated: DateTime.utc(2026, 1, 2),
      ),
    );

    final status = await db.getIndexStatus('manifest');
    expect(status?.embeddingProvider, 'OpenAI');
    expect(status?.contentHash, 'content');
    expect(status?.configHash, 'config');
  });

  test('replacing a canonical range removes its stale lexical row', () async {
    final db = RagDatabaseService();
    await db.saveChunk(
      _ragSampleChunk(
        bookId: 'replace',
        chunkId: 'old',
        charStart: 0,
        charEnd: 20,
        text: 'obsolete quasar passage',
      ),
    );
    await db.saveChunk(
      _ragSampleChunk(
        bookId: 'replace',
        chunkId: 'new',
        charStart: 0,
        charEnd: 20,
        text: 'current nebula passage',
      ),
    );

    expect(
      await db.searchLexical(
        matchQuery: '"quasar"',
        bookIds: ['replace'],
      ),
      isEmpty,
    );
    final current = await db.searchLexical(
      matchQuery: '"nebula"',
      bookIds: ['replace'],
    );
    expect(current.single.chunk.chunkId, 'new');
  });

  test('migrates a version-1 database to manifest columns and FTS', () async {
    final dbPath = p.join(await getDatabasesPath(), 'rag.db');
    final legacy = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE rag_chunks (
            chunkId TEXT PRIMARY KEY, bookId TEXT NOT NULL, text TEXT NOT NULL,
            embedding BLOB NOT NULL, embeddingDimension INTEGER NOT NULL,
            chapterIndex INTEGER, charStart INTEGER NOT NULL,
            charEnd INTEGER NOT NULL, tokenStart INTEGER NOT NULL,
            tokenEnd INTEGER NOT NULL, createdAt TEXT NOT NULL,
            UNIQUE(bookId, charStart)
          )
        ''');
        await db.execute('''
          CREATE TABLE rag_index_status (
            bookId TEXT PRIMARY KEY, status TEXT NOT NULL,
            totalChunks INTEGER NOT NULL, indexedChunks INTEGER NOT NULL,
            lastUpdated TEXT NOT NULL, errorMessage TEXT,
            embeddingModel TEXT NOT NULL, embeddingDimension INTEGER NOT NULL
          )
        ''');
      },
    );
    await legacy.close();

    final migrated = await RagDatabaseService().database;
    final columns = await migrated.rawQuery('PRAGMA table_info(rag_index_status)');
    expect(columns.map((row) => row['name']), containsAll([
      'embeddingProvider',
      'contentHash',
      'chunkingVersion',
      'indexVersion',
    ]));
    final fts = await migrated.query(
      'sqlite_master',
      where: 'name = ?',
      whereArgs: ['rag_chunks_fts'],
    );
    expect(fts, isNotEmpty);
  });
}
