import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import '../models/saved_translation.dart';

class SavedTranslationDatabaseService {
  static final SavedTranslationDatabaseService _instance = 
      SavedTranslationDatabaseService._internal();
  factory SavedTranslationDatabaseService() => _instance;
  SavedTranslationDatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFile = path.join(dbPath, 'saved_translations.db');

    return await openDatabase(
      dbFile,
      version: 1,
      onCreate: (db, version) async {
        // Create saved_translations table
        await db.execute('''
          CREATE TABLE saved_translations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bookId TEXT NOT NULL,
            original TEXT NOT NULL,
            pronunciation TEXT,
            translation TEXT NOT NULL,
            createdAt TEXT NOT NULL
          )
        ''');

        // Create index for better query performance
        await db.execute('''
          CREATE INDEX idx_book_translations ON saved_translations(bookId)
        ''');
      },
    );
  }

  /// Save a new translation
  Future<int> saveTranslation(SavedTranslation translation) async {
    final db = await database;
    return await db.insert(
      'saved_translations',
      translation.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all translations for a specific book
  Future<List<SavedTranslation>> getTranslations(String bookId) async {
    final db = await database;
    final results = await db.query(
      'saved_translations',
      where: 'bookId = ?',
      whereArgs: [bookId],
      orderBy: 'createdAt DESC',
    );

    return results
        .map((json) => SavedTranslation.fromJson(json))
        .toList();
  }

  /// Get count of saved translations for a specific book
  Future<int> getTranslationsCount(String bookId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM saved_translations WHERE bookId = ?',
      [bookId],
    );

    if (result.isEmpty) return 0;
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Search translations across all three columns (case-insensitive)
  Future<List<SavedTranslation>> searchTranslations(
    String bookId,
    String query,
  ) async {
    final db = await database;
    final lowerQuery = '%${query.toLowerCase()}%';
    
    final results = await db.query(
      'saved_translations',
      where: '''
        bookId = ? AND (
          LOWER(original) LIKE ? OR 
          LOWER(pronunciation) LIKE ? OR 
          LOWER(translation) LIKE ?
        )
      ''',
      whereArgs: [bookId, lowerQuery, lowerQuery, lowerQuery],
      orderBy: 'createdAt DESC',
    );

    return results
        .map((json) => SavedTranslation.fromJson(json))
        .toList();
  }

  /// Delete a specific translation
  Future<int> deleteTranslation(int id) async {
    final db = await database;
    return await db.delete(
      'saved_translations',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete all translations for a specific book
  Future<int> deleteAllForBook(String bookId) async {
    final db = await database;
    return await db.delete(
      'saved_translations',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
  }

  /// Clear all translations
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('saved_translations');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}

