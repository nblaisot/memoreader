import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;

/// Service for caching API responses (OpenAI, Mistral, etc.)
/// 
/// Caches API responses based on a hash of the full request payload.
/// Each cache entry is associated with a book ID for easy cleanup.
class ApiCacheService {
  static final ApiCacheService _instance = ApiCacheService._internal();
  factory ApiCacheService() => _instance;
  ApiCacheService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFile = path.join(dbPath, 'api_cache.db');

    return await openDatabase(
      dbFile,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE api_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            requestHash TEXT NOT NULL UNIQUE,
            bookId TEXT NOT NULL,
            responseText TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            provider TEXT NOT NULL
          )
        ''');

        // Create indices for better query performance
        await db.execute('''
          CREATE INDEX idx_request_hash ON api_cache(requestHash)
        ''');
        await db.execute('''
          CREATE INDEX idx_book_id ON api_cache(bookId)
        ''');
      },
    );
  }

  /// Compute a hash of the full request payload
  /// 
  /// This includes all request parameters: model, messages, max_tokens, temperature, etc.
  /// The hash includes the provider name to ensure OpenAI and Mistral responses are cached separately.
  /// The hash is used as the cache key to ensure identical requests return cached responses.
  /// 
  /// [provider] - The provider name (e.g., 'openai', 'mistral') - will be included in the hash
  /// [requestPayload] - The full request payload to hash
  String computeRequestHash(String provider, Map<String, dynamic> requestPayload) {
    // Sort keys to ensure consistent hashing regardless of key order
    final sortedPayload = Map.fromEntries(
      requestPayload.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final jsonString = jsonEncode(sortedPayload);
    // Include provider name in the hash to separate OpenAI and Mistral caches
    final combinedString = '$provider:$jsonString';
    final bytes = utf8.encode(combinedString);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  /// Get cached response for a request hash
  /// 
  /// Returns the cached response if found, null otherwise.
  Future<String?> getCachedResponse(String requestHash) async {
    try {
      final db = await database;
      final results = await db.query(
        'api_cache',
        columns: ['responseText'],
        where: 'requestHash = ?',
        whereArgs: [requestHash],
        limit: 1,
      );

      if (results.isNotEmpty) {
        return results.first['responseText'] as String;
      }
      return null;
    } catch (e) {
      debugPrint('Error getting cached response: $e');
      return null;
    }
  }

  /// Save a response to cache
  /// 
  /// [requestHash] is the hash of the full request payload
  /// [bookId] is the ID of the book this request is associated with
  /// [responseText] is the API response text
  /// [provider] is the provider name (e.g., 'openai', 'mistral')
  Future<void> saveCachedResponse(
    String requestHash,
    String bookId,
    String responseText,
    String provider,
  ) async {
    try {
      final db = await database;
      await db.insert(
        'api_cache',
        {
          'requestHash': requestHash,
          'bookId': bookId,
          'responseText': responseText,
          'createdAt': DateTime.now().toIso8601String(),
          'provider': provider,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('Error saving cached response: $e');
    }
  }

  /// Clear all cache entries for a specific book
  Future<void> clearCacheForBook(String bookId) async {
    try {
      final db = await database;
      await db.delete(
        'api_cache',
        where: 'bookId = ?',
        whereArgs: [bookId],
      );
      debugPrint('Cleared API cache for book: $bookId');
    } catch (e) {
      debugPrint('Error clearing cache for book: $e');
    }
  }

  /// Clear all cache entries
  Future<void> clearAllCache() async {
    try {
      final db = await database;
      await db.delete('api_cache');
      debugPrint('Cleared all API cache');
    } catch (e) {
      debugPrint('Error clearing all cache: $e');
    }
  }

  /// Get cache statistics for a book
  Future<Map<String, dynamic>> getCacheStats(String bookId) async {
    try {
      final db = await database;
      final results = await db.rawQuery(
        '''
        SELECT 
          COUNT(*) as count,
          provider
        FROM api_cache
        WHERE bookId = ?
        GROUP BY provider
        ''',
        [bookId],
      );

      final stats = <String, int>{};
      for (final row in results) {
        stats[row['provider'] as String] = row['count'] as int;
      }

      return {
        'total': results.fold<int>(0, (sum, row) => sum + (row['count'] as int)),
        'byProvider': stats,
      };
    } catch (e) {
      debugPrint('Error getting cache stats: $e');
      return {'total': 0, 'byProvider': {}};
    }
  }
}

