import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import '../models/book_summary_chunk.dart';
import '../models/book_summary_cache.dart';

class SummaryDatabaseService {
  static final SummaryDatabaseService _instance = SummaryDatabaseService._internal();
  factory SummaryDatabaseService() => _instance;
  SummaryDatabaseService._internal();

  Database? _database;
  Set<String>? _summaryCacheColumns;

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
      version: 10,  // Increment version to add characterIndex columns
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
            eventsJson TEXT,
            characterNotesJson TEXT,
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
            lastProcessedWordIndex INTEGER,
            lastProcessedCharacterIndex INTEGER,
            lastReadingStopChunkIndex INTEGER,
            lastReadingStopWordIndex INTEGER,
            lastReadingStopCharacterIndex INTEGER,
            lastReadingStopTimestamp TEXT,
            previousReadingStopChunkIndex INTEGER,
            previousReadingStopWordIndex INTEGER,
            previousReadingStopCharacterIndex INTEGER,
            previousReadingStopTimestamp TEXT,
            summarySinceLastTime TEXT,
            summarySinceLastTimeChunkIndex INTEGER,
            summarySinceLastTimeWordIndex INTEGER,
            summarySinceLastTimeCharacterIndex INTEGER,
            charactersSummary TEXT,
            charactersSummaryChunkIndex INTEGER,
            charactersSummaryWordIndex INTEGER,
            charactersSummaryCharacterIndex INTEGER,
            importantWords TEXT,
            generalSummaryJson TEXT,
            generalSummaryUpdatedAt TEXT,
            sinceLastTimeJson TEXT,
            sinceLastTimeUpdatedAt TEXT,
            characterProfilesJson TEXT,
            characterProfilesUpdatedAt TEXT
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
        if (oldVersion < 9) {
          try {
            await db.execute('''
              ALTER TABLE summary_chunks 
              ADD COLUMN eventsJson TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_chunks 
              ADD COLUMN characterNotesJson TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN generalSummaryJson TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN generalSummaryUpdatedAt TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN sinceLastTimeJson TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN sinceLastTimeUpdatedAt TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN characterProfilesJson TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN characterProfilesUpdatedAt TEXT
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
        }
        if (oldVersion < 10) {
          // Add wordIndex columns (legacy support) if they don't exist
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastProcessedWordIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastReadingStopWordIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN previousReadingStopWordIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN summarySinceLastTimeWordIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN charactersSummaryWordIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          // Add characterIndex columns to replace wordIndex-based tracking
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastProcessedCharacterIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN lastReadingStopCharacterIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN previousReadingStopCharacterIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN summarySinceLastTimeCharacterIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
          try {
            await db.execute('''
              ALTER TABLE summary_cache 
              ADD COLUMN charactersSummaryCharacterIndex INTEGER
            ''');
          } catch (e) {
            // Column might already exist, ignore
          }
        }
      },
    );
  }

  Future<Set<String>> _getSummaryCacheColumns(Database db) async {
    if (_summaryCacheColumns != null) {
      return _summaryCacheColumns!;
    }

    final columnsInfo = await db.rawQuery('PRAGMA table_info(summary_cache)');
    final columns = columnsInfo
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();

    _summaryCacheColumns = columns;
    return columns;
  }

  Future<Map<String, dynamic>> _filterDataForSummaryCache(
    Database db,
    Map<String, dynamic> data,
  ) async {
    final columns = await _getSummaryCacheColumns(db);
    return Map<String, dynamic>.fromEntries(
      data.entries.where((entry) => columns.contains(entry.key)),
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
    final filteredData = await _filterDataForSummaryCache(db, cache.toJson());

    await db.insert(
      'summary_cache',
      filteredData,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateLastSummaryView(String bookId, int chunkIndex) async {
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

  Future<void> updateLastReadingStop(
    String bookId, {
    required int chunkIndex,
    required int characterIndex,
    int? wordIndex,
  }) async {
    final cache = await getSummaryCache(bookId);
    final now = DateTime.now();
    if (cache != null) {
      // When user stops reading, move lastReadingStop to previousReadingStop,
      // and update lastReadingStop to current position with current timestamp
      final updatedCache = cache.copyWith(
        previousReadingStopChunkIndex: cache.lastReadingStopChunkIndex,
        previousReadingStopWordIndex: cache.lastReadingStopWordIndex,
        previousReadingStopCharacterIndex: cache.lastReadingStopCharacterIndex,
        previousReadingStopTimestamp: cache.lastReadingStopTimestamp,
        lastReadingStopChunkIndex: chunkIndex,
        lastReadingStopWordIndex: wordIndex,
        lastReadingStopCharacterIndex: characterIndex,
        lastReadingStopTimestamp: now,
        summarySinceLastTime: null,
        summarySinceLastTimeChunkIndex: null,
        summarySinceLastTimeWordIndex: null,
        summarySinceLastTimeCharacterIndex: null,
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
        lastReadingStopWordIndex: wordIndex,
        lastReadingStopCharacterIndex: characterIndex,
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

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('summary_chunks');
    await db.delete('summary_cache');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}

