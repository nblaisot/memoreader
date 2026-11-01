import 'dart:typed_data';
import 'dart:math' as math;
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
  static const int schemaVersion = 4;
  static const int indexVersion = 3;
  static final RagDatabaseService _instance = RagDatabaseService._internal();
  factory RagDatabaseService() => _instance;
  RagDatabaseService._internal();

  Database? _database;
  String _ftsMode = 'none';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFile = path.join(dbPath, 'rag.db');

    return await openDatabase(
      dbFile,
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
          await _addColumn(db, 'rag_index_status', 'extractionVersion INTEGER');
          await _addColumn(db, 'rag_index_status', 'chunkingVersion INTEGER');
          await _addColumn(db, 'rag_index_status', 'configHash TEXT');
          await _addColumn(db, 'rag_index_status', 'indexVersion INTEGER');
        }
        if (oldVersion < 3) {
          await _createFtsTable(db);
          await _rebuildFts(db);
        }
        if (oldVersion < 4) await _createStagingTable(db);
      },
      onOpen: (db) async {
        await _createFtsTable(db);
        await _createStagingTable(db);
      },
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
    await db.execute('CREATE TABLE IF NOT EXISTS rag_chunks_staging '
        'AS SELECT * FROM rag_chunks WHERE 0');
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_rag_stage_range '
        'ON rag_chunks_staging(bookId, charStart)');
  }

  Future<int> getStagedChunkCount(String bookId) async {
    final rows = await (await database).rawQuery(
        'SELECT COUNT(*) AS count FROM rag_chunks_staging WHERE bookId = ?', [bookId]);
    return rows.first['count'] as int;
  }

  Future<void> clearStagingBook(String bookId) async {
    await (await database).delete('rag_chunks_staging',
        where: 'bookId = ?', whereArgs: [bookId]);
  }

  Future<void> saveStagedChunks(List<RagChunk> chunks) async {
    if (chunks.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final chunk in chunks) {
        batch.insert('rag_chunks_staging', {
          ...chunk.toJson(), 'embedding': chunk.embeddingToBlob(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> activateStagedBook(String bookId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('rag_chunks_fts', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('rag_chunks', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.rawInsert('INSERT INTO rag_chunks SELECT * FROM rag_chunks_staging '
          'WHERE bookId = ?', [bookId]);
      await txn.rawInsert('INSERT INTO rag_chunks_fts(chunkId, bookId, text, chapterTitle) '
          'SELECT chunkId, bookId, text, COALESCE(chapterTitle, \'\') '
          'FROM rag_chunks_staging WHERE bookId = ?', [bookId]);
      await txn.delete('rag_chunks_staging', where: 'bookId = ?', whereArgs: [bookId]);
    });
  }

  Future<void> _createFtsTable(Database db) async {
    if (_ftsMode != 'none') return;
    final existing = await db.query(
      'sqlite_master',
      columns: ['sql'],
      where: 'type = ? AND name = ?',
      whereArgs: ['table', 'rag_chunks_fts'],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final sql = (existing.first['sql'] as String? ?? '').toLowerCase();
      if (sql.contains('using fts5')) {
        _ftsMode = 'fts5';
        return;
      }
      if (sql.contains('using fts4')) {
        _ftsMode = 'fts4';
        return;
      }
    }
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS rag_chunks_fts USING fts5(
          chunkId UNINDEXED,
          bookId UNINDEXED,
          text,
          chapterTitle,
          tokenize = 'unicode61 remove_diacritics 2'
        )
      ''');
      _ftsMode = 'fts5';
    } on DatabaseException {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS rag_chunks_fts USING fts4(
          chunkId,
          bookId,
          text,
          chapterTitle,
          tokenize=unicode61
        )
      ''');
      _ftsMode = 'fts4';
    }
  }

  static Future<void> _rebuildFts(Database db) async {
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
        'chunkId': chunk.chunkId,
        'bookId': chunk.bookId,
        'text': chunk.text,
        'embedding': chunk.embeddingToBlob(),
        'embeddingDimension': chunk.embeddingDimension,
        'chapterIndex': chunk.chapterIndex,
        'chapterTitle': chunk.chapterTitle,
        'sectionIndex': chunk.sectionIndex,
        'contentFileKey': chunk.contentFileKey,
        'charStart': chunk.charStart,
        'charEnd': chunk.charEnd,
        'tokenStart': chunk.tokenStart,
        'tokenEnd': chunk.tokenEnd,
        'createdAt': chunk.createdAt.toIso8601String(),
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
        'chunkId': chunk.chunkId,
        'bookId': chunk.bookId,
        'text': chunk.text,
        'embedding': chunk.embeddingToBlob(),
        'embeddingDimension': chunk.embeddingDimension,
        'chapterIndex': chunk.chapterIndex,
        'chapterTitle': chunk.chapterTitle,
        'sectionIndex': chunk.sectionIndex,
        'contentFileKey': chunk.contentFileKey,
        'charStart': chunk.charStart,
        'charEnd': chunk.charEnd,
        'tokenStart': chunk.tokenStart,
        'tokenEnd': chunk.tokenEnd,
        'createdAt': chunk.createdAt.toIso8601String(),
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
    List<(int charStart, int charEnd)> chunkRanges,
    {bool staging = false}
  ) async {
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
      'SELECT * FROM rag_chunks WHERE bookId IN ($placeholders) ORDER BY bookId, charStart ASC',
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
    final hits = <RagLexicalHit>[];
    final perBookLimit = math.min(limit, math.max(1, limit ~/ bookIds.length));

    for (final bookId in bookIds) {
      final boundary = boundaries[bookId];
      final rankExpression = _ftsMode == 'fts5'
          ? 'bm25(rag_chunks_fts)'
          : "matchinfo(rag_chunks_fts, 'pcx')";
      // FTS4 cannot order by matchinfo in SQL. Page matches and retain only
      // the strongest hits, rather than applying LIMIT before scoring.
      var offset = 0;
      final bookHits = <RagLexicalHit>[];
      while (true) {
        final rows = await db.rawQuery(
          '''
          SELECT c.*, $rankExpression AS lexicalRank
          FROM rag_chunks_fts
          JOIN rag_chunks c ON c.chunkId = rag_chunks_fts.chunkId
          WHERE rag_chunks_fts MATCH ? AND c.bookId = ?
            ${boundary == null ? '' : 'AND c.charStart < ?'}
          ${_ftsMode == 'fts5' ? 'ORDER BY lexicalRank ASC LIMIT ?' : 'LIMIT ? OFFSET ?'}
          ''',
          [matchQuery, bookId, if (boundary != null) boundary,
            if (_ftsMode == 'fts5') perBookLimit else ...[200, offset]],
        );
        for (final row in rows) {
          final rawRank = _ftsMode == 'fts5'
              ? (row['lexicalRank'] as num?)?.toDouble() ?? 0
              : _scoreFts4MatchInfo(row['lexicalRank'] as Uint8List?);
          bookHits.add(RagLexicalHit(
            chunk: RagChunk.fromJson(row, row['embedding'] as Uint8List),
            score: _ftsMode == 'fts5' ? -rawRank : rawRank,
          ));
        }
        bookHits.sort((a, b) => b.score.compareTo(a.score));
        if (bookHits.length > perBookLimit) {
          bookHits.removeRange(perBookLimit, bookHits.length);
        }
        if (_ftsMode == 'fts5' || rows.length < 200) break;
        offset += rows.length;
      }
      hits.addAll(bookHits);
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  static double _scoreFts4MatchInfo(Uint8List? bytes) {
    if (bytes == null || bytes.length < 8) return 0;
    final data = ByteData.sublistView(bytes);
    final phraseCount = data.getUint32(0, Endian.host);
    final columnCount = data.getUint32(4, Endian.host);
    var offset = 8;
    var score = 0.0;
    for (var phrase = 0; phrase < phraseCount; phrase++) {
      for (var column = 0; column < columnCount; column++) {
        if (offset + 12 > bytes.length) return score;
        final hitsHere = data.getUint32(offset, Endian.host);
        final hitsAllRows = data.getUint32(offset + 4, Endian.host);
        final rowsWithHits = data.getUint32(offset + 8, Endian.host);
        if (hitsHere > 0) {
          score += hitsHere / (1 + hitsAllRows) + 1 / (1 + rowsWithHits);
        }
        offset += 12;
      }
    }
    return score;
  }

  /// Get all book IDs that have been fully indexed
  Future<List<String>> getAllIndexedBookIds() async {
    final db = await database;
    final results = await db.query(
      'rag_index_status',
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
    await db.delete('rag_chunks_fts');
    await db.delete('rag_chunks');
    await db.delete('rag_chunks_staging');
    await db.delete('rag_index_status');
  }

  /// Clear RAG data for a specific book
  Future<void> clearBook(String bookId) async {
    final db = await database;
    await db.delete('rag_chunks_fts', where: 'bookId = ?', whereArgs: [bookId]);
    await db.delete('rag_chunks', where: 'bookId = ?', whereArgs: [bookId]);
    await db.delete('rag_chunks_staging', where: 'bookId = ?', whereArgs: [bookId]);
    await db.delete(
      'rag_index_status',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
  }

  /// Close the database
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _ftsMode = 'none';
    }
  }
}
