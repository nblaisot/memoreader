import 'book.dart';
import 'reading_progress.dart';
import 'saved_translation.dart';

/// Wrapper for syncing books data
class SyncBooksData {
  final List<Book> books;
  final Map<String, DateTime> deletedBooks; // Map of bookId -> deletion timestamp
  final DateTime lastModified;

  SyncBooksData({
    required this.books,
    required this.deletedBooks,
    required this.lastModified,
  });

  Map<String, dynamic> toJson() {
    return {
      'books': books.map((b) => b.toJson()).toList(),
      'deletedBooks': deletedBooks.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      ),
      'lastModified': lastModified.toIso8601String(),
    };
  }

  factory SyncBooksData.fromJson(Map<String, dynamic> json, {
    required String booksDirectory,
    required String coversDirectory,
  }) {
    final deletedBooksMap = <String, DateTime>{};
    if (json['deletedBooks'] != null) {
      (json['deletedBooks'] as Map<String, dynamic>).forEach((key, value) {
        deletedBooksMap[key] = DateTime.parse(value as String);
      });
    }
    
    return SyncBooksData(
      books: (json['books'] as List)
          .map((b) => Book.fromJson(
                b as Map<String, dynamic>,
                booksDirectory: booksDirectory,
                coversDirectory: coversDirectory,
              ))
          .toList(),
      deletedBooks: deletedBooksMap,
      lastModified: DateTime.parse(json['lastModified'] as String),
    );
  }
}

/// Wrapper for syncing reading progress data
class SyncProgressData {
  final Map<String, ReadingProgress> progress;
  final DateTime lastModified;

  SyncProgressData({
    required this.progress,
    required this.lastModified,
  });

  Map<String, dynamic> toJson() {
    return {
      'progress': progress.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'lastModified': lastModified.toIso8601String(),
    };
  }

  factory SyncProgressData.fromJson(Map<String, dynamic> json) {
    final progressMap = <String, ReadingProgress>{};
    if (json['progress'] != null) {
      (json['progress'] as Map<String, dynamic>).forEach((key, value) {
        progressMap[key] = ReadingProgress.fromJson(value as Map<String, dynamic>);
      });
    }
    return SyncProgressData(
      progress: progressMap,
      lastModified: DateTime.parse(json['lastModified'] as String),
    );
  }
}

/// Wrapper for syncing saved translations data
class SyncTranslationsData {
  final List<SavedTranslation> translations;
  final DateTime lastModified;

  SyncTranslationsData({
    required this.translations,
    required this.lastModified,
  });

  Map<String, dynamic> toJson() {
    return {
      'translations': translations.map((t) => t.toJson()).toList(),
      'lastModified': lastModified.toIso8601String(),
    };
  }

  factory SyncTranslationsData.fromJson(Map<String, dynamic> json) {
    return SyncTranslationsData(
      translations: (json['translations'] as List)
          .map((t) => SavedTranslation.fromJson(t as Map<String, dynamic>))
          .toList(),
      lastModified: DateTime.parse(json['lastModified'] as String),
    );
  }
}

/// Wrapper for syncing API keys data
class SyncApiKeysData {
  final String? openaiApiKey;
  final String? mistralApiKey;
  final String? provider; // 'openai' or 'mistral'
  final DateTime lastModified;

  SyncApiKeysData({
    this.openaiApiKey,
    this.mistralApiKey,
    this.provider,
    required this.lastModified,
  });

  Map<String, dynamic> toJson() {
    return {
      'openaiApiKey': openaiApiKey,
      'mistralApiKey': mistralApiKey,
      'provider': provider,
      'lastModified': lastModified.toIso8601String(),
    };
  }

  factory SyncApiKeysData.fromJson(Map<String, dynamic> json) {
    return SyncApiKeysData(
      openaiApiKey: json['openaiApiKey'] as String?,
      mistralApiKey: json['mistralApiKey'] as String?,
      provider: json['provider'] as String?,
      lastModified: DateTime.parse(json['lastModified'] as String),
    );
  }
}
