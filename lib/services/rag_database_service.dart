import 'dart:typed_data';
import 'dart:io';
import 'rag_native_database.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import '../models/rag_chunk.dart';
import '../models/rag_index_progress.dart';

class RagLexicalHit {
  const RagLexicalHit({required this.chunk, required this.score});

  final RagChunk chunk;
  final double score;
}

class RagDatabaseService {
  static const int schemaVersion = 6;
  static const int indexVersion = 4;
  static final RagDatabaseService _instance = RagDatabaseService._internal();
  factory RagDatabaseService() => _instance;
  RagDatabaseService._internal();

  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database async {
    if (_database != null) return _database!;
    try {
      _database = await (_opening ??= _initDatabase());
    } catch (_) {
      _opening = null;
      rethrow;
    }
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFile = path.join(dbPath, 'rag-v5.db');

    return await ragDatabaseFactory.openDatabase(
      dbFile,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, version) async {
          // Create rag_chunks table
          await db.execute('''
          CREATE TABLE rag_chunks (
            chunkId TEXT PRIMARY KEY,
            bookId TEXT NOT NULL,
            text TEXT NOT NULL,
            embedding BLOB NOT NULL,
            embeddingDimension INTEGER NOT NULL,
            chapterIndex INTEGER,
            chapterTitle TEXT,
            sectionIndex INTEGER,
            contentFileKey TEXT,
            charStart INTEGER NOT NULL,
            charEnd INTEGER NOT NULL,
            tokenStart INTEGER NOT NULL,
            tokenEnd INTEGER NOT NULL,
            createdAt TEXT NOT NULL,
            tokenCount INTEGER NOT NULL DEFAULT 0,
            previousChunkId TEXT,
            nextChunkId TEXT,
            UNIQUE(bookId, charStart)
          )
        ''');

          // Create rag_index_status table
          await db.execute('''
          CREATE TABLE rag_index_status (
            bookId TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            totalChunks INTEGER NOT NULL,
            indexedChunks INTEGER NOT NULL,
            lastUpdated TEXT NOT NULL,
            errorMessage TEXT,
            embeddingModel TEXT NOT NULL,
            embeddingProvider TEXT,
            embeddingDimension INTEGER NOT NULL,
            contentHash TEXT,
            extractionVersion INTEGER,
            chunkingVersion INTEGER,
            configHash TEXT,
            indexVersion INTEGER
          )
        ''');

          // Create indices for better query performance
          await db.execute('''
          CREATE INDEX idx_rag_book ON rag_chunks(bookId)
        ''');

          await db.execute('''
          CREATE INDEX idx_rag_char_range ON rag_chunks(bookId, charStart, charEnd)
        ''');
          await _createFtsTable(db);
          await _createStagingTable(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _addColumn(db, 'rag_chunks', 'chapterTitle TEXT');
            await _addColumn(db, 'rag_chunks', 'sectionIndex INTEGER');
            await _addColumn(db, 'rag_chunks', 'contentFileKey TEXT');
            await _addColumn(db, 'rag_index_status', 'embeddingProvider TEXT');
            await _addColumn(db, 'rag_index_status', 'contentHash TEXT');
            await _addColumn(
              db,
              'rag_index_status',
              'extractionVersion INTEGER',
            );
            await _addColumn(db, 'rag_index_status', 'chunkingVersion INTEGER');
            await _addColumn(db, 'rag_index_status', 'configHash TEXT');
            await _addColumn(db, 'rag_index_status', 'indexVersion INTEGER');
          }
          if (oldVersion < 3) {
            await _createFtsTable(db);
            await _rebuildFts(db);
          }
          if (oldVersion < 4) await _createStagingTable(db);
          if (oldVersion < 6) {
            for (final table in ['rag_chunks', 'rag_chunks_staging']) {
              await _addColumn(
                db,
                table,
                'tokenCount INTEGER NOT NULL DEFAULT 0',
              );
              await _addColumn(db, table, 'previousChunkId TEXT');
              await _addColumn(db, table, 'nextChunkId TEXT');
            }
          }
        },
        onOpen: (db) async {
          await db.execute('PRAGMA recursive_triggers = ON');
          await db.execute('PRAGMA busy_timeout = 10000');
          await db.execute(
            'CREATE TABLE IF NOT EXISTS rag_leases(bookId TEXT PRIMARY KEY,owner TEXT,expires INTEGER)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS rag_generations(bookId TEXT PRIMARY KEY,generationId TEXT)',
          );
          await db.execute('PRAGMA journal_mode = WAL');
          await db.execute(
            'CREATE TABLE IF NOT EXISTS rag_readers(id TEXT PRIMARY KEY,expires INTEGER)',
          );
          await _createFtsTable(db);
          await _createStagingTable(db);
          await db.execute(
            'CREATE TABLE IF NOT EXISTS rag_active_status AS SELECT * FROM rag_index_status WHERE 0',
          );
          await db.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS idx_active_book ON rag_active_status(bookId)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS rag_jobs(bookId TEXT PRIMARY KEY, fileSize INTEGER, fileModified INTEGER, configIdentity TEXT, state TEXT, updated TEXT)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS rag_prefix_vectors(bookId TEXT, boundary INTEGER, identity TEXT, chunkId TEXT, embedding BLOB, PRIMARY KEY(bookId,boundary,identity,chunkId))',
          );
          await _migrateLegacy(db, path.join(dbPath, 'rag.db'));
          final dimensions = await db.rawQuery(
            'SELECT DISTINCT embeddingDimension FROM rag_chunks WHERE embeddingDimension > 0',
          );
          for (final row in dimensions) {
            await _ensureVectorTable(db, row['embeddingDimension'] as int);
          }
        },
      ),
    );
  }

  static Future<void> _addColumn(
    Database db,
    String table,
    String definition,
  ) async {
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $definition');
    } on DatabaseException catch (error) {
      if (!error.toString().toLowerCase().contains('duplicate column')) {
        rethrow;
      }
    }
  }

  static Future<void> _createStagingTable(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS rag_chunks_staging '
      'AS SELECT * FROM rag_chunks WHERE 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_rag_stage_range '
      'ON rag_chunks_staging(bookId, charStart)',
    );
  }

  Future<int> getStagedChunkCount(String bookId) async {
    final rows = await (await database).rawQuery(
      'SELECT COUNT(*) AS count FROM rag_chunks_staging WHERE bookId = ?',
      [bookId],
    );
    return rows.first['count'] as int;
  }

  Future<void> clearStagingBook(String bookId) async {
    await (await database).delete(
      'rag_chunks_staging',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
  }

  Future<void> saveStagedChunks(List<RagChunk> chunks) async {
    if (chunks.isEmpty) return;
    for (final chunk in chunks) {
      if (chunk.embeddingDimension != chunk.embedding.length ||
          chunk.embedding.isEmpty ||
          chunk.embedding.any((v) => !v.isFinite)) {
        throw ArgumentError('Invalid passage vector');
      }
    }
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final chunk in chunks) {
        batch.insert('rag_chunks_staging', {
          ...chunk.toJson(),
          'embedding': chunk.embeddingToBlob(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> activateStagedBook(String bookId) async {
    final db = await database;
    final dimensions = await db.rawQuery(
      'SELECT DISTINCT embeddingDimension FROM rag_chunks_staging WHERE bookId = ?',
      [bookId],
    );
    for (final row in dimensions) {
      await _ensureVectorTable(db, row['embeddingDimension'] as int);
    }
    await db.transaction((txn) async {
      final expected = await txn.query(
        'rag_index_status',
        where: 'bookId = ?',
        whereArgs: [bookId],
      );
      final count = await txn.rawQuery(
        'SELECT count(*) AS n FROM rag_chunks_staging WHERE bookId = ?',
        [bookId],
      );
      if (count.first['n'] == 0 ||
          (expected.isNotEmpty &&
              expected.first['totalChunks'] != count.first['n'])) {
        throw StateError('Incomplete staged generation');
      }

      await txn.delete(
        'rag_chunks_fts',
        where: 'bookId = ?',
        whereArgs: [bookId],
      );
      await txn.delete('rag_chunks', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.rawInsert(
        'INSERT INTO rag_chunks SELECT * FROM rag_chunks_staging '
        'WHERE bookId = ?',
        [bookId],
      );
      await txn.rawInsert(
        'INSERT INTO rag_chunks_fts(chunkId, bookId, text, chapterTitle) '
        'SELECT chunkId, bookId, text, COALESCE(chapterTitle, \'\') '
        'FROM rag_chunks_staging WHERE bookId = ?',
        [bookId],
      );
      await txn.delete(
        'rag_chunks_staging',
        where: 'bookId = ?',
        whereArgs: [bookId],
      );
      await txn.execute(
        "INSERT OR REPLACE INTO rag_active_status SELECT * FROM rag_index_status WHERE bookId = ?",
        [bookId],
      );
      final manifest = expected.firstOrNull;
      await txn.insert('rag_generations', {
        'bookId': bookId,
        'generationId':
            '${manifest?['contentHash']}:${manifest?['configHash']}:${DateTime.now().microsecondsSinceEpoch}',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        'rag_prefix_vectors',
        where: 'bookId = ?',
        whereArgs: [bookId],
      );
      await txn.update(
        'rag_active_status',
        {'status': 'completed'},
        where: 'bookId = ?',
        whereArgs: [bookId],
      );
    });
  }

  Future<void> _createFtsTable(Database db) async {
    await db.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS rag_chunks_fts USING fts5(chunkId UNINDEXED, bookId UNINDEXED, text, chapterTitle, tokenize = 'unicode61 remove_diacritics 2')",
    );
  }

  static Future<void> _migrateLegacy(Database db, String legacy) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS rag_metadata(key TEXT PRIMARY KEY,value TEXT)',
    );
    if ((await db.query(
      'rag_metadata',
      where: 'key = ?',
      whereArgs: ['legacyImported'],
    )).isNotEmpty) {
      return;
    }
    if (!await File(legacy).exists()) {
      await db.insert('rag_metadata', {
        'key': 'legacyImported',
        'value': 'none',
      });
      return;
    }
    final rows = await db.rawQuery(
      'SELECT count(*) AS n FROM rag_index_status',
    );
    if (rows.first['n'] != 0) return;
    await db.execute('ATTACH DATABASE ? AS legacy', [legacy]);
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM legacy.sqlite_master WHERE name = 'rag_index_status'",
      );
      if (tables.isEmpty) return;
      await db.transaction((txn) async {
        for (final table in ['rag_chunks', 'rag_index_status']) {
          final old = await txn.rawQuery('PRAGMA legacy.table_info($table)');
          final current = await txn.rawQuery('PRAGMA main.table_info($table)');
          final oldNames = old.map((r) => r['name']).toSet();
          final columns = current
              .map((r) => r['name'])
              .where(oldNames.contains)
              .join(',');
          await txn.execute(
            'INSERT OR IGNORE INTO $table($columns) SELECT $columns FROM legacy.$table',
          );
        }
        await _rebuildFts(txn);
        await txn.insert('rag_metadata', {
          'key': 'legacyImported',
          'value': 'complete',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.execute(
          "INSERT OR REPLACE INTO rag_active_status SELECT * FROM rag_index_status WHERE status = 'completed'",
        );
      });
    } finally {
      await db.execute('DETACH DATABASE legacy');
    }
  }

  static Future<void> _ensureVectorTable(Database db, int dimensions) async {
    if (dimensions <= 0 || dimensions > 65536) {
      throw ArgumentError('Invalid vector dimensions');
    }
    final name = 'rag_vec_$dimensions';
    final exists = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name = ?",
      [name],
    );
    if (exists.isNotEmpty) return;
    await db.transaction((txn) async {
      if ((await txn.rawQuery('SELECT name FROM sqlite_master WHERE name = ?', [
        name,
      ])).isNotEmpty) {
        return;
      }
      await txn.execute(
        'CREATE VIRTUAL TABLE $name USING vec0(chunkRowid INTEGER PRIMARY KEY, embedding float[$dimensions] distance_metric=cosine, bookId TEXT, charEnd INTEGER)',
      );
      await txn.execute(
        'CREATE TRIGGER ${name}_insert AFTER INSERT ON rag_chunks WHEN new.embeddingDimension = $dimensions BEGIN INSERT INTO $name(chunkRowid, embedding, bookId, charEnd) VALUES(new.rowid,new.embedding,new.bookId,new.charEnd); END',
      );
      await txn.execute(
        'CREATE TRIGGER ${name}_delete AFTER DELETE ON rag_chunks WHEN old.embeddingDimension = $dimensions BEGIN DELETE FROM $name WHERE chunkRowid = old.rowid; END',
      );
      await txn.execute(
        'INSERT INTO $name(chunkRowid,embedding,bookId,charEnd) SELECT rowid,embedding,bookId,charEnd FROM rag_chunks WHERE embeddingDimension = $dimensions',
      );
    });
  }

  static (String, List<Object?>) _eligibleScope(
    List<String> books,
    Map<String, int?> boundaries, {
    String prefix = '',
  }) {
    if (boundaries.isEmpty) {
      return (
        '${prefix}bookId IN (${List.filled(books.length, '?').join(',')})',
        books,
      );
    }
    final clauses = <String>[];
    final args = <Object?>[];
    for (final book in books) {
      if (boundaries.containsKey(book)) {
        final end = boundaries[book];
        if (end == null || end <= 0) continue;
        clauses.add('(${prefix}bookId = ? AND ${prefix}charEnd <= ?)');
        args.addAll([book, end]);
      } else {
        clauses.add('${prefix}bookId = ?');
        args.add(book);
      }
    }
    return (clauses.join(' OR '), args);
  }

  Future<List<RagLexicalHit>> searchSemantic({
    required Float32List vector,
    required List<String> bookIds,
    Map<String, int?> boundaries = const {},
    int limit = 40,
  }) async {
    if (vector.isEmpty || bookIds.isEmpty) return [];
    final db = await database;
    await _ensureVectorTable(db, vector.length);
    final scope = _eligibleScope(bookIds, boundaries);
    if (scope.$1.isEmpty) return [];
    final matches = await db.rawQuery(
      'SELECT chunkRowid,distance FROM rag_vec_${vector.length} WHERE embedding MATCH ? AND k = ? AND chunkRowid IN (SELECT rowid FROM rag_chunks WHERE ${scope.$1}) ORDER BY distance',
      [
        Uint8List.view(
          vector.buffer,
          vector.offsetInBytes,
          vector.lengthInBytes,
        ),
        limit,
        ...scope.$2,
      ],
    );
    final ranked = matches
        .map(
          (r) => (
            rowid: r['chunkRowid'] as int,
            score: 1 - (r['distance'] as num).toDouble(),
          ),
        )
        .toList();
    final best = ranked.take(limit).toList();
    if (best.isEmpty) return [];
    final placeholders = List.filled(best.length, '?').join(',');
    final rows = await db.rawQuery(
      "SELECT chunkId, bookId, text, embeddingDimension, chapterIndex, chapterTitle, sectionIndex, contentFileKey, charStart, charEnd, tokenStart, tokenEnd, createdAt, X'' AS embedding FROM rag_chunks WHERE rowid IN ($placeholders)",
      best.map((r) => r.rowid).toList(),
    );
    final byId = {
      for (final r in rows)
        r['chunkId'] as String: RagChunk.fromJson(r, Uint8List(0)),
    };
    // rowids are loaded separately to avoid transporting embedding BLOBs.
    final ids = await db.rawQuery(
      'SELECT rowid,chunkId FROM rag_chunks WHERE rowid IN ($placeholders)',
      best.map((r) => r.rowid).toList(),
    );
    final rowToId = {
      for (final r in ids) r['rowid'] as int: r['chunkId'] as String,
    };
    return best
        .map(
          (r) => RagLexicalHit(chunk: byId[rowToId[r.rowid]]!, score: r.score),
        )
        .toList();
  }

  Future<Map<String, Float32List>> prefixVectors(
    String bookId,
    int boundary,
    String identity,
  ) async {
    final rows = await (await database).query(
      'rag_prefix_vectors',
      where: 'bookId = ? AND boundary = ? AND identity = ?',
      whereArgs: [bookId, boundary, identity],
    );
    return {
      for (final r in rows)
        r['chunkId'] as String: RagChunk.embeddingFromBlob(
          r['embedding'] as Uint8List,
        ),
    };
  }

  Future<void> savePrefixVector(
    String bookId,
    int boundary,
    String identity,
    String chunkId,
    Float32List vector,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      // Retain only the latest prepared boundary per book/provider.
      await txn.delete(
        'rag_prefix_vectors',
        where: 'bookId = ? AND (boundary != ? OR identity != ?)',
        whereArgs: [bookId, boundary, identity],
      );
      await txn.insert('rag_prefix_vectors', {
        'bookId': bookId,
        'boundary': boundary,
        'identity': identity,
        'chunkId': chunkId,
        'embedding': Uint8List.view(
          vector.buffer,
          vector.offsetInBytes,
          vector.lengthInBytes,
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> beginInteractive(String id) async => (await database)
      .insert('rag_readers', {
        'id': id,
        'expires': DateTime.now().millisecondsSinceEpoch + 180000,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<void> endInteractive(String id) async => (await database)
      .delete('rag_readers', where: 'id = ?', whereArgs: [id])
      .then((_) {});
  Future<bool> hasInteractiveReaders() async =>
      (await (await database).rawQuery(
        'SELECT id FROM rag_readers WHERE expires > ? LIMIT 1',
        [DateTime.now().millisecondsSinceEpoch],
      )).isNotEmpty;

  Future<bool> acquireLease(String bookId, String owner) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await database;
    return db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT INTO rag_leases(bookId,owner,expires) VALUES(?,?,?) ON CONFLICT(bookId) DO UPDATE SET owner=excluded.owner,expires=excluded.expires WHERE rag_leases.expires < ?',
        [bookId, owner, now + 180000, now],
      );
      final rows = await txn.query(
        'rag_leases',
        where: 'bookId = ? AND owner = ?',
        whereArgs: [bookId, owner],
      );
      return rows.isNotEmpty;
    });
  }

  Future<void> releaseLease(String bookId, String owner) async =>
      (await database).execute(
        'DELETE FROM rag_leases WHERE bookId = ? AND owner = ?',
        [bookId, owner],
      );

  Future<List<RagChunk>> adjacentPassages(
    RagChunk passage, {
    int? boundary,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      "WITH scoped AS (SELECT * FROM rag_chunks WHERE bookId = ? AND sectionIndex IS ?) SELECT chunkId, bookId, text, embeddingDimension, chapterIndex, chapterTitle, sectionIndex, contentFileKey, charStart, charEnd, tokenStart, tokenEnd, createdAt, X'' AS embedding FROM scoped WHERE charStart >= COALESCE((SELECT MAX(charStart) FROM scoped WHERE charStart < ?), ?) AND charStart <= COALESCE((SELECT MIN(charStart) FROM scoped WHERE charStart >= ?), ?) ORDER BY charStart",
      [
        passage.bookId,
        passage.sectionIndex,
        passage.charStart,
        passage.charStart,
        passage.charEnd,
        passage.charEnd,
      ],
    );
    return rows
        .where((r) => boundary == null || (r['charStart'] as int) < boundary)
        .map((r) {
          final c = RagChunk.fromJson(r, Uint8List(0));
          return boundary != null && c.charEnd > boundary
              ? c.copyWith(
                  text: c.text.substring(0, boundary - c.charStart),
                  charEnd: boundary,
                )
              : c;
        })
        .toList();
  }

  Future<List<RagChunk>> crossingPassages(String bookId, int boundary) async {
    final rows = await (await database).rawQuery(
      "SELECT chunkId, bookId, text, embeddingDimension, chapterIndex, chapterTitle, sectionIndex, contentFileKey, charStart, charEnd, tokenStart, tokenEnd, createdAt, X'' AS embedding FROM rag_chunks WHERE bookId = ? AND charStart < ? AND charEnd > ?",
      [bookId, boundary, boundary],
    );
    return rows.map((r) {
      final c = RagChunk.fromJson(r, Uint8List(0));
      return c.copyWith(
        text: c.text.substring(0, boundary - c.charStart),
        charEnd: boundary,
      );
    }).toList();
  }

  Future<List<Map<String, Object?>>> activeManifests(List<String> books) async {
    if (books.isEmpty) return [];
    return (await database).rawQuery(
      'SELECT s.*,g.generationId FROM rag_active_status s LEFT JOIN rag_generations g ON s.bookId=g.bookId WHERE s.bookId IN (${List.filled(books.length, '?').join(',')})',
      books,
    );
  }

  Future<RagIndexProgress?> getActiveIndexStatus(String bookId) async {
    final rows = await (await database).query(
      'rag_active_status',
      where: 'bookId = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return rows.isEmpty ? null : RagIndexProgress.fromJson(rows.first);
  }

  Future<Map<String, Object?>?> getJob(String bookId) async {
    final rows = await (await database).query(
      'rag_jobs',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveJob(String bookId, Map<String, Object?> job) async {
    await (await database).insert('rag_jobs', {
      'bookId': bookId,
      ...job,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _rebuildFts(DatabaseExecutor db) async {
    await db.delete('rag_chunks_fts');
    await db.rawInsert('''
      INSERT INTO rag_chunks_fts(chunkId, bookId, text, chapterTitle)
      SELECT chunkId, bookId, text, COALESCE(chapterTitle, '') FROM rag_chunks
    ''');
  }

  // Chunk operations

  /// Save a chunk with its embedding
  Future<void> saveChunk(RagChunk chunk) async {
    final db = await database;
    await _ensureVectorTable(db, chunk.embeddingDimension);
    await db.transaction((txn) async {
      final replaced = await txn.query(
        'rag_chunks',
        columns: ['chunkId'],
        where: 'bookId = ? AND charStart = ?',
        whereArgs: [chunk.bookId, chunk.charStart],
      );
      for (final row in replaced) {
        await txn.delete(
          'rag_chunks_fts',
          where: 'chunkId = ?',
          whereArgs: [row['chunkId']],
        );
      }
      await txn.insert('rag_chunks', {
        ...chunk.toJson(),
        'embedding': chunk.embeddingToBlob(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('rag_chunks_fts', {
        'chunkId': chunk.chunkId,
        'bookId': chunk.bookId,
        'text': chunk.text,
        'chapterTitle': chunk.chapterTitle ?? '',
      });
    });
  }

  /// Save multiple chunks in a transaction (more efficient)
  Future<void> saveChunks(List<RagChunk> chunks) async {
    if (chunks.isEmpty) return;

    final db = await database;
    for (final d in chunks.map((c) => c.embeddingDimension).toSet()) {
      await _ensureVectorTable(db, d);
    }
    final batch = db.batch();

    // Remove FTS rows for chunks replaced through UNIQUE(bookId, charStart),
    // including the case where the new chunk has a new UUID.
    for (final chunk in chunks) {
      final replaced = await db.query(
        'rag_chunks',
        columns: ['chunkId'],
        where: 'bookId = ? AND charStart = ?',
        whereArgs: [chunk.bookId, chunk.charStart],
      );
      for (final row in replaced) {
        batch.delete(
          'rag_chunks_fts',
          where: 'chunkId = ?',
          whereArgs: [row['chunkId']],
        );
      }
    }

    for (final chunk in chunks) {
      batch.insert('rag_chunks', {
        ...chunk.toJson(),
        'embedding': chunk.embeddingToBlob(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('rag_chunks_fts', {
        'chunkId': chunk.chunkId,
        'bookId': chunk.bookId,
        'text': chunk.text,
        'chapterTitle': chunk.chapterTitle ?? '',
      });
    }

    await batch.commit(noResult: true);
  }

  /// Get all chunks for a book
  Future<List<RagChunk>> getChunks(String bookId) async {
    final db = await database;
    final results = await db.query(
      'rag_chunks',
      where: 'bookId = ?',
      whereArgs: [bookId],
      orderBy: 'charStart ASC',
    );

    return results.map((row) {
      final embeddingBlob = row['embedding'] as Uint8List;
      return RagChunk.fromJson(row, embeddingBlob);
    }).toList();
  }

  /// Get chunks intersecting the text before an exclusive reading boundary.
  Future<List<RagChunk>> getChunksUpToPosition(
    String bookId,
    int maxCharEnd,
  ) async {
    final db = await database;
    final results = await db.query(
      'rag_chunks',
      where: 'bookId = ? AND charStart < ?',
      whereArgs: [bookId, maxCharEnd],
      orderBy: 'charStart ASC',
    );

    return results.map((row) {
      final embeddingBlob = row['embedding'] as Uint8List;
      return RagChunk.fromJson(row, embeddingBlob);
    }).toList();
  }

  /// Get the last N chunks intersecting an exclusive reading boundary.
  /// Returns chunks in chronological order (oldest to newest)
  Future<List<RagChunk>> getLastNChunksUpToPosition(
    String bookId,
    int maxCharEnd,
    int limit,
  ) async {
    final db = await database;
    final results = await db.query(
      'rag_chunks',
      where: 'bookId = ? AND charStart < ?',
      whereArgs: [bookId, maxCharEnd],
      orderBy: 'charEnd DESC',
      limit: limit,
    );

    // Reverse to get chronological order (oldest to newest)
    return results.reversed.map((row) {
      final embeddingBlob = row['embedding'] as Uint8List;
      return RagChunk.fromJson(row, embeddingBlob);
    }).toList();
  }

  /// Check if a chunk already exists (for idempotent indexing)
  Future<bool> chunkExists(String bookId, int charStart, int charEnd) async {
    final db = await database;
    final results = await db.query(
      'rag_chunks',
      columns: ['chunkId'],
      where: 'bookId = ? AND charStart = ? AND charEnd = ?',
      whereArgs: [bookId, charStart, charEnd],
      limit: 1,
    );
    return results.isNotEmpty;
  }

  /// Check which chunks already exist (batch operation for performance)
  /// Returns a Set of (charStart, charEnd) tuples for existing chunks
  Future<Set<(int, int)>> chunksExist(
    String bookId,
    List<(int charStart, int charEnd)> chunkRanges, {
    bool staging = false,
  }) async {
    if (chunkRanges.isEmpty) return {};

    final db = await database;

    // SQLite doesn't support tuple IN clause directly, so we use OR conditions
    // For large lists, we'll batch the query to avoid SQL statement size limits
    const maxBatchSize = 400; // 2 placeholders per range plus book ID
    final existingChunks = <(int, int)>{};

    for (int i = 0; i < chunkRanges.length; i += maxBatchSize) {
      final batch = chunkRanges.sublist(
        i,
        i + maxBatchSize > chunkRanges.length
            ? chunkRanges.length
            : i + maxBatchSize,
      );

      // Build OR conditions: (charStart = ? AND charEnd = ?) OR ...
      final conditions = batch
          .map((_) => '(charStart = ? AND charEnd = ?)')
          .join(' OR ');
      final args = batch.expand((r) => [r.$1, r.$2]).toList();

      final results = await db.rawQuery(
        'SELECT charStart, charEnd FROM ${staging ? 'rag_chunks_staging' : 'rag_chunks'} WHERE bookId = ? AND ($conditions)',
        [bookId, ...args],
      );

      for (final row in results) {
        existingChunks.add((row['charStart'] as int, row['charEnd'] as int));
      }
    }

    return existingChunks;
  }

  /// Delete all chunks for a book
  Future<void> deleteChunks(String bookId) async {
    final db = await database;
    await db.delete('rag_chunks_fts', where: 'bookId = ?', whereArgs: [bookId]);
    await db.delete('rag_chunks', where: 'bookId = ?', whereArgs: [bookId]);
  }

  /// Get count of chunks for a book
  Future<int> getChunkCount(String bookId) async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT COUNT(*) as count FROM rag_chunks WHERE bookId = ?',
      [bookId],
    );
    return results.first['count'] as int;
  }

  // Index status operations

  /// Save or update index status
  Future<void> saveIndexStatus(RagIndexProgress progress) async {
    final db = await database;
    await db.execute('UPDATE rag_leases SET expires = ? WHERE bookId = ?', [
      DateTime.now().millisecondsSinceEpoch + 180000,
      progress.bookId,
    ]);
    final existingRows = await db.query(
      'rag_index_status',
      where: 'bookId = ?',
      whereArgs: [progress.bookId],
      limit: 1,
    );
    final existing = existingRows.isEmpty
        ? null
        : RagIndexProgress.fromJson(existingRows.first);
    await db.insert('rag_index_status', {
      'bookId': progress.bookId,
      'status': progress.status.name,
      'totalChunks': progress.totalChunks,
      'indexedChunks': progress.indexedChunks,
      'lastUpdated': progress.lastUpdated.toIso8601String(),
      'errorMessage': progress.errorMessage,
      'embeddingModel':
          progress.embeddingModel ?? existing?.embeddingModel ?? '',
      'embeddingProvider':
          progress.embeddingProvider ?? existing?.embeddingProvider,
      'embeddingDimension':
          progress.embeddingDimension ?? existing?.embeddingDimension ?? 0,
      'contentHash': progress.contentHash ?? existing?.contentHash,
      'extractionVersion':
          progress.extractionVersion ?? existing?.extractionVersion,
      'chunkingVersion': progress.chunkingVersion ?? existing?.chunkingVersion,
      'configHash': progress.configHash ?? existing?.configHash,
      'indexVersion': progress.indexVersion ?? existing?.indexVersion,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Get index status for a book
  Future<RagIndexProgress?> getIndexStatus(String bookId) async {
    final db = await database;
    final results = await db.query(
      'rag_index_status',
      where: 'bookId = ?',
      whereArgs: [bookId],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return RagIndexProgress.fromJson(results.first);
  }

  /// Update index status status field
  Future<void> updateIndexStatus(
    String bookId,
    RagIndexStatus status, {
    String? errorMessage,
  }) async {
    final db = await database;
    await db.update(
      'rag_index_status',
      {
        'status': status.name,
        'lastUpdated': DateTime.now().toIso8601String(),
        if (errorMessage != null) 'errorMessage': errorMessage,
      },
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
  }

  /// Update indexed chunks count
  Future<void> updateIndexedChunks(String bookId, int indexedChunks) async {
    final db = await database;
    await db.update(
      'rag_index_status',
      {
        'indexedChunks': indexedChunks,
        'lastUpdated': DateTime.now().toIso8601String(),
      },
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
  }

  /// Increment indexed chunks count atomically and return the new count
  Future<int> incrementIndexedChunks(String bookId, int incrementBy) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE rag_index_status
      SET indexedChunks = indexedChunks + ?, lastUpdated = ?
      WHERE bookId = ?
      ''',
      [incrementBy, DateTime.now().toIso8601String(), bookId],
    );

    final results = await db.rawQuery(
      'SELECT indexedChunks FROM rag_index_status WHERE bookId = ?',
      [bookId],
    );

    if (results.isEmpty) {
      return incrementBy;
    }

    return results.first['indexedChunks'] as int;
  }

  /// Get all chunks for a list of books (for multi-book queries)
  Future<List<RagChunk>> getChunksForBooks(List<String> bookIds) async {
    if (bookIds.isEmpty) return [];
    final db = await database;
    final placeholders = bookIds.map((_) => '?').join(', ');
    final results = await db.rawQuery(
      "SELECT chunkId, bookId, text, embeddingDimension, chapterIndex, chapterTitle, sectionIndex, contentFileKey, charStart, charEnd, tokenStart, tokenEnd, createdAt, X'' AS embedding FROM rag_chunks WHERE bookId IN ($placeholders) ORDER BY bookId, charStart ASC",
      bookIds,
    );
    return results.map((row) {
      final embeddingBlob = row['embedding'] as Uint8List;
      return RagChunk.fromJson(row, embeddingBlob);
    }).toList();
  }

  /// Search the on-device FTS index, respecting book scope and exclusive
  /// spoiler boundaries before results enter fusion.
  Future<List<RagLexicalHit>> searchLexical({
    required String matchQuery,
    required List<String> bookIds,
    Map<String, int?> boundaries = const {},
    int limit = 50,
  }) async {
    if (matchQuery.trim().isEmpty || bookIds.isEmpty) return [];
    final db = await database;
    final scope = _eligibleScope(bookIds, boundaries, prefix: 'c.');
    if (scope.$1.isEmpty) return [];
    final rows = await db.rawQuery(
      'SELECT c.chunkId,bm25(rag_chunks_fts) AS lexicalRank FROM rag_chunks_fts JOIN rag_chunks c ON c.chunkId=rag_chunks_fts.chunkId WHERE rag_chunks_fts MATCH ? AND (${scope.$1}) ORDER BY lexicalRank LIMIT ?',
      [matchQuery, ...scope.$2, limit],
    );
    final ranked = rows
        .map(
          (r) => (
            id: r['chunkId'] as String,
            score: -(r['lexicalRank'] as num).toDouble(),
          ),
        )
        .toList();
    final prefixes = <RagLexicalHit>[];
    for (final book in bookIds) {
      final end = boundaries[book];
      if (end == null || end <= 0) continue;
      final terms = RegExp(
        r'"([^"]+)"',
      ).allMatches(matchQuery).map((m) => m[1]!.toLowerCase()).toList();
      for (final c in await crossingPassages(book, end)) {
        if (terms.any((t) => c.text.toLowerCase().contains(t))) {
          prefixes.add(RagLexicalHit(chunk: c, score: 0));
        }
      }
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    final best = ranked.take(limit).toList();
    final hits = <RagLexicalHit>[];
    if (best.isNotEmpty) {
      final placeholders = List.filled(best.length, '?').join(',');
      final rows = await db.rawQuery(
        "SELECT chunkId,bookId,text,embeddingDimension,chapterIndex,chapterTitle,sectionIndex,contentFileKey,charStart,charEnd,tokenStart,tokenEnd,createdAt,tokenCount,previousChunkId,nextChunkId FROM rag_chunks WHERE chunkId IN ($placeholders)",
        best.map((r) => r.id).toList(),
      );
      final byId = {
        for (final r in rows)
          r['chunkId'] as String: RagChunk.fromJson(r, Uint8List(0)),
      };
      hits.addAll(
        best.map((r) => RagLexicalHit(chunk: byId[r.id]!, score: r.score)),
      );
    }
    hits.addAll(prefixes);
    return hits.take(limit + prefixes.length).toList();
  }

  Future<List<String>> getAllIndexedBookIds() async {
    final db = await database;
    final results = await db.query(
      'rag_active_status',
      columns: ['bookId'],
      where: 'status = ?',
      whereArgs: ['completed'],
    );
    return results.map((row) => row['bookId'] as String).toList();
  }

  /// Get all books that need indexing (no status or status is pending/error)
  Future<List<String>> getBooksNeedingIndexing() async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT DISTINCT bookId FROM rag_chunks
      WHERE bookId NOT IN (SELECT bookId FROM rag_index_status WHERE status = 'completed')
      UNION
      SELECT bookId FROM rag_index_status WHERE status IN ('pending', 'error')
    ''');

    return results.map((row) => row['bookId'] as String).toList();
  }

  // Database management

  /// Clear all RAG data (chunks and status)
  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      for (final table in [
        'rag_chunks_fts',
        'rag_chunks',
        'rag_chunks_staging',
        'rag_index_status',
        'rag_active_status',
        'rag_jobs',
        'rag_generations',
        'rag_prefix_vectors',
        'rag_leases',
        'rag_readers',
      ]) {
        await txn.delete(table);
      }
    });
  }

  /// Delete the active generation, pending work, and derived caches together.
  Future<void> clearBook(String bookId) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final table in [
        'rag_chunks_fts',
        'rag_chunks',
        'rag_chunks_staging',
        'rag_index_status',
        'rag_active_status',
        'rag_jobs',
        'rag_generations',
        'rag_prefix_vectors',
        'rag_leases',
      ]) {
        await txn.delete(table, where: 'bookId = ?', whereArgs: [bookId]);
      }
    });
  }

  /// Close the database
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _opening = null;
    }
  }
}
