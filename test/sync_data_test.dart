import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/models/reading_progress.dart';
import 'package:memoreader/models/saved_translation.dart';
import 'package:memoreader/models/sync_data.dart';

void main() {
  const booksDir = '/app/books';
  const coversDir = '/app/covers';

  // ---------------------------------------------------------------------------
  // SyncBooksData
  // ---------------------------------------------------------------------------

  test('SyncBooksData round-trip', () {
    final book = Book(
      id: 'id1',
      title: 'Title',
      author: 'Auth',
      filePath: '$booksDir/id1.epub',
      coverImagePath: '$coversDir/id1.png',
      dateAdded: DateTime.utc(2024, 2, 1),
    );
    final original = SyncBooksData(
      books: [book],
      deletedBooks: {'gone': DateTime.utc(2024, 3, 1)},
      lastModified: DateTime.utc(2024, 4, 1),
    );

    final json = original.toJson();
    final restored = SyncBooksData.fromJson(
      json,
      booksDirectory: booksDir,
      coversDirectory: coversDir,
    );

    expect(restored.books.single.id, book.id);
    expect(restored.books.single.title, book.title);
    expect(restored.deletedBooks.keys, contains('gone'));
    expect(restored.lastModified, original.lastModified);
  });

  test('SyncBooksData with empty books list round-trips', () {
    final original = SyncBooksData(
      books: [],
      deletedBooks: {},
      lastModified: DateTime.utc(2025, 1, 1),
    );
    final restored = SyncBooksData.fromJson(
      original.toJson(),
      booksDirectory: booksDir,
      coversDirectory: coversDir,
    );
    expect(restored.books, isEmpty);
    expect(restored.deletedBooks, isEmpty);
  });

  test('SyncBooksData with null deletedBooks key in JSON is handled', () {
    final json = <String, dynamic>{
      'books': <dynamic>[],
      'deletedBooks': null,
      'lastModified': DateTime.utc(2025, 1, 1).toIso8601String(),
    };
    final restored = SyncBooksData.fromJson(
      json,
      booksDirectory: booksDir,
      coversDirectory: coversDir,
    );
    expect(restored.deletedBooks, isEmpty);
  });

  test('SyncBooksData with multiple tombstones round-trips all of them', () {
    final original = SyncBooksData(
      books: [],
      deletedBooks: {
        'a': DateTime.utc(2025, 1, 1),
        'b': DateTime.utc(2025, 2, 2),
        'c': DateTime.utc(2025, 3, 3),
      },
      lastModified: DateTime.utc(2025, 4, 1),
    );
    final restored = SyncBooksData.fromJson(
      original.toJson(),
      booksDirectory: booksDir,
      coversDirectory: coversDir,
    );
    expect(restored.deletedBooks.length, 3);
    expect(restored.deletedBooks['b'], DateTime.utc(2025, 2, 2));
  });

  // ---------------------------------------------------------------------------
  // SyncProgressData
  // ---------------------------------------------------------------------------

  test('SyncProgressData round-trip', () {
    final p = ReadingProgress(
      bookId: 'b',
      lastRead: DateTime.utc(2025, 1, 2),
      progress: 0.5,
      currentCharacterIndex: 10,
      lastVisibleCharacterIndex: 9,
    );
    final original = SyncProgressData(
      progress: {'b': p},
      lastModified: DateTime.utc(2025, 1, 3),
    );
    final restored = SyncProgressData.fromJson(original.toJson());
    expect(restored.progress['b']!.bookId, 'b');
    expect(restored.progress['b']!.progress, 0.5);
  });

  test('SyncProgressData with empty progress map round-trips', () {
    final original = SyncProgressData(
      progress: {},
      lastModified: DateTime.utc(2025, 1, 1),
    );
    final restored = SyncProgressData.fromJson(original.toJson());
    expect(restored.progress, isEmpty);
  });

  test('SyncProgressData with null progress key in JSON is handled', () {
    final json = <String, dynamic>{
      'progress': null,
      'lastModified': DateTime.utc(2025, 1, 1).toIso8601String(),
    };
    final restored = SyncProgressData.fromJson(json);
    expect(restored.progress, isEmpty);
  });

  test('SyncProgressData ignores unknown extra JSON keys', () {
    final json = <String, dynamic>{
      'progress': <String, dynamic>{},
      'lastModified': DateTime.utc(2025, 1, 1).toIso8601String(),
      'unknownFutureField': 'should be ignored',
    };
    expect(() => SyncProgressData.fromJson(json), returnsNormally);
  });

  // ---------------------------------------------------------------------------
  // SyncTranslationsData
  // ---------------------------------------------------------------------------

  test('SyncTranslationsData round-trip', () {
    final t = SavedTranslation(
      id: 1,
      bookId: 'b',
      original: 'hello',
      translation: 'bonjour',
      createdAt: DateTime.utc(2025, 6, 1),
    );
    final original = SyncTranslationsData(
      translations: [t],
      lastModified: DateTime.utc(2025, 6, 2),
    );
    final restored = SyncTranslationsData.fromJson(original.toJson());
    expect(restored.translations.single.original, 'hello');
  });

  test('SyncTranslationsData with empty list round-trips', () {
    final original = SyncTranslationsData(
      translations: [],
      lastModified: DateTime.utc(2025, 1, 1),
    );
    final restored = SyncTranslationsData.fromJson(original.toJson());
    expect(restored.translations, isEmpty);
  });

  test('SyncTranslationsData ignores unknown extra JSON keys', () {
    final json = <String, dynamic>{
      'translations': <dynamic>[],
      'lastModified': DateTime.utc(2025, 1, 1).toIso8601String(),
      'futureField': 42,
    };
    expect(() => SyncTranslationsData.fromJson(json), returnsNormally);
  });

  // ---------------------------------------------------------------------------
  // SyncApiKeysData
  // ---------------------------------------------------------------------------

  test('SyncApiKeysData round-trip', () {
    final original = SyncApiKeysData(
      openaiApiKey: 'o',
      mistralApiKey: 'm',
      provider: 'openai',
      lastModified: DateTime.utc(2025, 7, 1),
    );
    final restored = SyncApiKeysData.fromJson(original.toJson());
    expect(restored.openaiApiKey, 'o');
    expect(restored.provider, 'openai');
  });

  test('SyncApiKeysData with all-null optional fields round-trips', () {
    final original = SyncApiKeysData(
      openaiApiKey: null,
      mistralApiKey: null,
      provider: null,
      lastModified: DateTime.utc(2025, 7, 1),
    );
    final restored = SyncApiKeysData.fromJson(original.toJson());
    expect(restored.openaiApiKey, isNull);
    expect(restored.mistralApiKey, isNull);
    expect(restored.provider, isNull);
  });

  test('SyncApiKeysData ignores unknown extra JSON keys', () {
    final json = <String, dynamic>{
      'openaiApiKey': 'sk-x',
      'mistralApiKey': null,
      'provider': null,
      'lastModified': DateTime.utc(2025, 1, 1).toIso8601String(),
      'futureFeatureFlag': true,
    };
    expect(() => SyncApiKeysData.fromJson(json), returnsNormally);
    final restored = SyncApiKeysData.fromJson(json);
    expect(restored.openaiApiKey, 'sk-x');
  });
}
