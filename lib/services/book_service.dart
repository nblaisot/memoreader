import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:epubx/epubx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import 'summary_database_service.dart';

class BookService {
  static const String _booksKey = 'books';
  static const String _progressKey = 'reading_progress_';
  
  final Uuid _uuid = const Uuid();

  Future<String> getBooksDirectory() async {
    try {
      final appDocumentsDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${appDocumentsDir.path}/books');
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }
      return booksDir.path;
    } catch (e) {
      throw Exception('Failed to access app documents directory: $e');
    }
  }

  /// Copy a file to app storage with the given extension
  /// 
  /// Used for EPUB and TXT files
  Future<String> copyFile(File sourceFile, String extension) async {
    try {
      if (!await sourceFile.exists()) {
        throw Exception('Source file does not exist');
      }
      final booksDir = await getBooksDirectory();
      final fileName = '${_uuid.v4()}.$extension';
      final destFile = File('$booksDir/$fileName');
      await sourceFile.copy(destFile.path);
      return destFile.path;
    } catch (e) {
      throw Exception('Failed to copy file: $e');
    }
  }

  /// Copy an EPUB file to app storage (backward compatibility)
  /// 
  /// @deprecated Use copyFile() instead
  Future<String> copyEpubFile(File sourceFile) async {
    return copyFile(sourceFile, 'epub');
  }

  /// Import a book file (EPUB or TXT)
  /// 
  /// Automatically detects the file format and extracts metadata accordingly
  Future<Book> importBook(File file) async {
    try {
      if (!await file.exists()) {
        throw Exception('File does not exist');
      }
      
      final extension = file.path.split('.').last.toLowerCase();
      String format;
      String? title;
      String? author;
      
      switch (extension) {
        case 'epub':
          format = 'epub';
          // Parse the EPUB to get metadata
          final epub = await EpubReader.readBook(await file.readAsBytes());
          title = epub.Title?.isNotEmpty == true ? epub.Title! : null;
          author = epub.Author?.isNotEmpty == true ? epub.Author! : null;
          break;
          
        case 'txt':
          format = 'txt';
          // For TXT, read first few lines to try to extract title
          try {
            final content = await file.readAsString(encoding: utf8);
            final lines = content.split('\n')
                .where((l) => l.trim().isNotEmpty)
                .take(5)
                .toList();
            if (lines.isNotEmpty) {
              title = lines.first.trim();
              // If title looks like it might be a heading, use it
              if (title.length > 100) {
                title = null; // Probably not a title if too long
              }
            }
            author = null;
          } catch (e) {
            debugPrint('Failed to read TXT file for metadata: $e');
          }
          break;
          
        default:
          throw Exception('Unsupported file format: $extension');
      }
      
      // Copy the file to app storage
      final storedPath = await copyFile(file, extension);
      
      final book = Book(
        id: _uuid.v4(),
        title: title?.isNotEmpty == true ? title! : 'Unknown Title',
        author: author?.isNotEmpty == true ? author! : 'Unknown Author',
        filePath: storedPath,
        dateAdded: DateTime.now(),
        format: format,
      );

      // Save book to preferences
      await _saveBook(book);
      
      return book;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to import book: $e');
    }
  }

  /// Import an EPUB file (backward compatibility)
  /// 
  /// @deprecated Use importBook() instead
  Future<Book> importEpub(File epubFile) async {
    try {
      if (!await epubFile.exists()) {
        throw Exception('EPUB file does not exist');
      }
      
      // Copy the file to app storage
      final storedPath = await copyFile(epubFile, 'epub');
      
      // Parse the EPUB to get metadata
      final epub = await EpubReader.readBook(await epubFile.readAsBytes());
      
      final book = Book(
        id: _uuid.v4(),
        title: epub.Title?.isNotEmpty == true ? epub.Title! : 'Unknown Title',
        author: epub.Author?.isNotEmpty == true ? epub.Author! : 'Unknown Author',
        filePath: storedPath,
        dateAdded: DateTime.now(),
        format: 'epub',
      );

      // Save book to preferences
      await _saveBook(book);
      
      return book;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to import EPUB: $e');
    }
  }

  Future<List<Book>> getAllBooks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final booksJson = prefs.getStringList(_booksKey) ?? [];
      return booksJson.map((json) {
        try {
          return Book.fromJson(jsonDecode(json));
        } catch (e) {
          // Skip corrupted book entries
          return null;
        }
      }).whereType<Book>().toList()
        ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded)); // Sort by date added, newest first
    } catch (e) {
      throw Exception('Failed to load books: $e');
    }
  }

  Future<void> _saveBook(Book book) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final books = await getAllBooks();
      
      // Check if book with same ID already exists
      if (books.any((b) => b.id == book.id)) {
        throw Exception('Book with this ID already exists');
      }
      
      books.add(book);
      final booksJson = books.map((b) => jsonEncode(b.toJson())).toList();
      await prefs.setStringList(_booksKey, booksJson);
    } catch (e) {
      throw Exception('Failed to save book: $e');
    }
  }

  Future<ReadingProgress?> getReadingProgress(String bookId) async {
    try {
      if (bookId.isEmpty) return null;
      final prefs = await SharedPreferences.getInstance();
      final progressJson = prefs.getString('$_progressKey$bookId');
      if (progressJson == null) return null;
      return ReadingProgress.fromJson(jsonDecode(progressJson));
    } catch (e) {
      // If progress is corrupted, return null to start fresh
      return null;
    }
  }

  Future<void> saveReadingProgress(ReadingProgress progress) async {
    try {
      if (progress.bookId.isEmpty) {
        throw Exception('Book ID cannot be empty');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_progressKey${progress.bookId}',
        jsonEncode(progress.toJson()),
      );
    } catch (e) {
      // Don't throw - progress saving failures shouldn't crash the app
      debugPrint('Failed to save reading progress: $e');
    }
  }

  Future<EpubBook> loadEpubBook(String filePath) async {
    try {
      if (filePath.isEmpty) {
        throw Exception('File path cannot be empty');
      }
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('EPUB file not found at path: $filePath');
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('EPUB file is empty');
      }
      final epub = await EpubReader.readBook(bytes);
      return epub;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to load EPUB book: $e');
    }
  }

  Future<void> deleteBook(Book book) async {
    try {
      // Remove from preferences
      final prefs = await SharedPreferences.getInstance();
      final books = await getAllBooks();
      books.removeWhere((b) => b.id == book.id);
      final booksJson = books.map((b) => jsonEncode(b.toJson())).toList();
      await prefs.setStringList(_booksKey, booksJson);
      
      // Delete file
      final file = File(book.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      
      // Delete reading progress
      await prefs.remove('$_progressKey${book.id}');
      
      // Delete summaries
      final summaryDb = SummaryDatabaseService();
      await summaryDb.deleteBookSummaries(book.id);
    } catch (e) {
      throw Exception('Failed to delete book: $e');
    }
  }
}
