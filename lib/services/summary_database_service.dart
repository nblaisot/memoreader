import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import '../models/book_summary_chunk.dart';
import '../models/book_summary_cache.dart';

class SummaryDatabaseService {
  static final SummaryDatabaseService _instance = SummaryDatabaseService._internal();
  factory SummaryDatabaseService() => _instance;
  SummaryDatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFile = path.join(dbPath, 'summaries.db');

    return await openDatabase(
      dbFile,
      version: 8,
      onCreate: (db, version) async {
        // Create summary_chunks table
        await db.execute('''
          CREATE TABLE summary_chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bookId TEXT NOT NULL,
            chunkIndex INTEGER NOT NULL,
            chunkType TEXT NOT NULL,
            summaryText TEXT NOT NULL,
            tokenCount INTEGER,
            createdAt TEXT NOT NULL,
            UNIQUE(bookId, chunkIndex)
          )
        ''');

        // Create summary_cache table
        await db.execute('''
          CREATE TABLE summary_cache (
            bookId TEXT PRIMARY KEY,
            lastProcessedChunkIndex INTEGER NOT NULL,
            cumulativeSummary TEXT NOT NULL,
            lastUpdated TEXT NOT NULL,
            lastSummaryViewChunkIndex INTEGER,
            lastReadingStopChunkIndex INTEGER,
            lastReadingStopTimestamp TEXT,
            previousReadingStopChunkIndex INTEGER,
            previousReadingStopTimestamp TEXT,
            summarySinceLastTime TEXT,
            summarySinceLastTimeChunkIndex INTEGER,
            charactersSummary TEXT,
            charactersSummaryChunkIndex INTEGER,
            importantWords TEXT
          )
        ''');

        // Create indices for better query performance
        await db.execute('''
          CREATE INDEX idx_book_chunk ON summary_chunks(bookId, chunkIndex)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Add new columns if upgrading from older versions
        if (oldVersion < 2) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastSummaryViewChunkIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
        }
        if (oldVersion < 3) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastReadingStopChunkIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
        }
        if (oldVersion < 4) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN previousReadingStopChunkIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
        }
        if (oldVersion < 5) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastReadingStopTimestamp TEXT
            ''');
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN previousReadingStopTimestamp TEXT
            ''');
          } catch (e) {
            // Columns might already exist, ignore
          }
        }
        if (oldVersion < 6) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN summarySinceLastTime TEXT
            ''');
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN summarySinceLastTimeChunkIndex INTEGER
            ''');
          } catch (e) {
            // Columns might already exist, ignore
          }
        }
        if (oldVersion < 7) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN charactersSummary TEXT
            ''');
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN charactersSummaryChunkIndex INTEGER
            ''');
          } catch (e) {
            // Columns might already exist, ignore
          }
        }
        if (oldVersion < 8) {
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN importantWords TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
        }
      },
    );
  }

  // Summary Chunk operations
  Future<void> saveSummaryChunk(BookSummaryChunk chunk) async {
    final db = await database;
    await db.insert(
      'summary_chunks',
      chunk.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<BookSummaryChunk>> getSummaryChunks(
    String bookId,
    int upToChunkIndex,
  ) async {
    final db = await database;
    final results = await db.query(
      'summary_chunks',
      where: 'bookId = ? AND chunkIndex <= ?',
      whereArgs: [bookId, upToChunkIndex],
      orderBy: 'chunkIndex ASC',
    );

    return results
        .map((json) => BookSummaryChunk.fromJson(json))
        .toList();
  }

  Future<BookSummaryChunk?> getSummaryChunk(
    String bookId,
    int chunkIndex,
  ) async {
    final db = await database;
    final results = await db.query(
      'summary_chunks',
      where: 'bookId = ? AND chunkIndex = ?',
      whereArgs: [bookId, chunkIndex],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return BookSummaryChunk.fromJson(results.first);
  }

  Future<int> getLastProcessedChunkIndex(String bookId) async {
    final db = await database;
    final results = await db.query(
      'summary_chunks',
      columns: ['MAX(chunkIndex) as maxIndex'],
      where: 'bookId = ?',
      whereArgs: [bookId],
    );

    if (results.isEmpty || results.first['maxIndex'] == null) {
      return -1;
    }
    return results.first['maxIndex'] as int;
  }

  // Summary Cache operations
  Future<void> saveSummaryCache(BookSummaryCache cache) async {
    final db = await database;
    await db.insert(
      'summary_cache',
      cache.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateLastSummaryView(String bookId, int chunkIndex) async {
    final db = await database;
    final cache = await getSummaryCache(bookId);
    if (cache != null) {
      final updatedCache = cache.copyWith(
        lastSummaryViewChunkIndex: chunkIndex,
      );
      await saveSummaryCache(updatedCache);
    } else {
      // If no cache exists, create one with minimal data
      final newCache = BookSummaryCache(
        bookId: bookId,
        lastProcessedChunkIndex: chunkIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
        lastSummaryViewChunkIndex: chunkIndex,
      );
      await saveSummaryCache(newCache);
    }
  }

  Future<void> updateLastReadingStop(String bookId, int chunkIndex) async {
    final db = await database;
    final cache = await getSummaryCache(bookId);
    final now = DateTime.now();
    if (cache != null) {
      // When user stops reading, move lastReadingStop to previousReadingStop,
      // and update lastReadingStop to current position with current timestamp
      final updatedCache = cache.copyWith(
        previousReadingStopChunkIndex: cache.lastReadingStopChunkIndex,
        previousReadingStopTimestamp: cache.lastReadingStopTimestamp,
        lastReadingStopChunkIndex: chunkIndex,
        lastReadingStopTimestamp: now,
      );
      await saveSummaryCache(updatedCache);
    } else {
      // If no cache exists, create one with minimal data
      final newCache = BookSummaryCache(
        bookId: bookId,
        lastProcessedChunkIndex: chunkIndex,
        cumulativeSummary: '',
        lastUpdated: DateTime.now(),
        lastReadingStopChunkIndex: chunkIndex,
        lastReadingStopTimestamp: now,
      );
      await saveSummaryCache(newCache);
    }
  }

  Future<BookSummaryCache?> getSummaryCache(String bookId) async {
    final db = await database;
    final results = await db.query(
      'summary_cache',
      where: 'bookId = ?',
      whereArgs: [bookId],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return BookSummaryCache.fromJson(results.first);
  }

  Future<void> deleteBookSummaries(String bookId) async {
    final db = await database;
    await db.delete(
      'summary_chunks',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
    await db.delete(
      'summary_cache',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
