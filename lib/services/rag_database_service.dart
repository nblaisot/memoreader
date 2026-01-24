import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import '../models/rag_chunk.dart';
import '../models/rag_index_progress.dart';

class RagDatabaseService {
  static final RagDatabaseService _instance = RagDatabaseService._internal();
  factory RagDatabaseService() => _instance;
  RagDatabaseService._internal();

  Database? _database;

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
      version: 1,
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
            embeddingDimension INTEGER NOT NULL
          )
        ''');

        // Create indices for better query performance
        await db.execute('''
          CREATE INDEX idx_rag_book ON rag_chunks(bookId)
        ''');
        
        await db.execute('''
          CREATE INDEX idx_rag_char_range ON rag_chunks(bookId, charStart, charEnd)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Future schema migrations can go here
        // For now, version 1 is the initial version
      },
    );
  }

  // Chunk operations

  /// Save a chunk with its embedding
  Future<void> saveChunk(RagChunk chunk) async {
    final db = await database;
    await db.insert(
      'rag_chunks',
      {
        'chunkId': chunk.chunkId,
        'bookId': chunk.bookId,
        'text': chunk.text,
        'embedding': chunk.embeddingToBlob(),
        'embeddingDimension': chunk.embeddingDimension,
        'chapterIndex': chunk.chapterIndex,
        'charStart': chunk.charStart,
        'charEnd': chunk.charEnd,
        'tokenStart': chunk.tokenStart,
        'tokenEnd': chunk.tokenEnd,
        'createdAt': chunk.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Save multiple chunks in a transaction (more efficient)
  Future<void> saveChunks(List<RagChunk> chunks) async {
    if (chunks.isEmpty) return;
    
    final db = await database;
    final batch = db.batch();
    
    for (final chunk in chunks) {
      batch.insert(
        'rag_chunks',
        {
          'chunkId': chunk.chunkId,
          'bookId': chunk.bookId,
          'text': chunk.text,
          'embedding': chunk.embeddingToBlob(),
          'embeddingDimension': chunk.embeddingDimension,
          'chapterIndex': chunk.chapterIndex,
          'charStart': chunk.charStart,
          'charEnd': chunk.charEnd,
          'tokenStart': chunk.tokenStart,
          'tokenEnd': chunk.tokenEnd,
          'createdAt': chunk.createdAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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

  /// Get chunks filtered by character position (for "read so far" queries)
  Future<List<RagChunk>> getChunksUpToPosition(
    String bookId,
    int maxCharEnd,
  ) async {
    final db = await database;
    final results = await db.query(
      'rag_chunks',
      where: 'bookId = ? AND charEnd <= ?',
      whereArgs: [bookId, maxCharEnd],
      orderBy: 'charStart ASC',
    );

    return results.map((row) {
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
  ) async {
    if (chunkRanges.isEmpty) return {};
    
    final db = await database;
    
    // SQLite doesn't support tuple IN clause directly, so we use OR conditions
    // For large lists, we'll batch the query to avoid SQL statement size limits
    const maxBatchSize = 500; // SQLite has limits on query size
    final existingChunks = <(int, int)>{};
    
    for (int i = 0; i < chunkRanges.length; i += maxBatchSize) {
      final batch = chunkRanges.sublist(
        i,
        i + maxBatchSize > chunkRanges.length ? chunkRanges.length : i + maxBatchSize,
      );
      
      // Build OR conditions: (charStart = ? AND charEnd = ?) OR ...
      final conditions = batch.map((_) => '(charStart = ? AND charEnd = ?)').join(' OR ');
      final args = batch.expand((r) => [r.$1, r.$2]).toList();
      
      final results = await db.rawQuery(
        'SELECT charStart, charEnd FROM rag_chunks WHERE bookId = ? AND ($conditions)',
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
    await db.delete(
      'rag_chunks',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
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
    await db.insert(
      'rag_index_status',
      {
        'bookId': progress.bookId,
        'status': progress.status.name,
        'totalChunks': progress.totalChunks,
        'indexedChunks': progress.indexedChunks,
        'lastUpdated': progress.lastUpdated.toIso8601String(),
        'errorMessage': progress.errorMessage,
        'embeddingModel': progress.embeddingModel ?? '',
        'embeddingDimension': progress.embeddingDimension ?? 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
      [
        incrementBy,
        DateTime.now().toIso8601String(),
        bookId,
      ],
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
    await db.delete('rag_chunks');
    await db.delete('rag_index_status');
  }

  /// Clear RAG data for a specific book
  Future<void> clearBook(String bookId) async {
    final db = await database;
    await db.delete(
      'rag_chunks',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
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
    }
  }
}
