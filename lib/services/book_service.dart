import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:epubx/epubx.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import '../models/book.dart';
import '../models/reading_progress.dart';
import 'summary_database_service.dart';
import 'api_cache_service.dart';

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

  Future<String> copyEpubFile(File sourceFile) async {
    try {
      if (!await sourceFile.exists()) {
        throw Exception('Source file does not exist');
      }
      final booksDir = await getBooksDirectory();
      final fileName = '${_uuid.v4()}.epub';
      final destFile = File('$booksDir/$fileName');
      await sourceFile.copy(destFile.path);
      return destFile.path;
    } catch (e) {
      throw Exception('Failed to copy EPUB file: $e');
    }
  }

  Future<Book> importEpub(File epubFile) async {
    try {
      if (!await epubFile.exists()) {
        throw Exception('EPUB file does not exist');
      }
      
      // Copy the file to app storage
      final storedPath = await copyEpubFile(epubFile);
      
      // Parse the EPUB to get metadata
      final epub = await EpubReader.readBook(await epubFile.readAsBytes());
      
      final bookId = _uuid.v4();
      
      // Extract cover image
      String? coverImagePath;
      try {
        coverImagePath = await _extractCoverImage(epub, bookId);
      } catch (e) {
        debugPrint('Failed to extract cover image: $e');
        // Continue without cover image
      }
      
      final book = Book(
        id: bookId,
        title: epub.Title?.isNotEmpty == true ? epub.Title! : 'Unknown Title',
        author: epub.Author?.isNotEmpty == true ? epub.Author! : 'Unknown Author',
        coverImagePath: coverImagePath,
        filePath: storedPath,
        dateAdded: DateTime.now(),
      );

      // Save book to preferences
      await _saveBook(book);
      
      return book;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to import EPUB: $e');
    }
  }

  /// Extract cover image from EPUB and save it to disk
  Future<String?> _extractCoverImage(EpubBook epub, String bookId) async {
    try {
      String? coverPath;
      
      // Method 1: Check CoverImage property (Image object from image package)
      // Note: CoverImage is an Image object from the image package (dependency of epubx)
      if (epub.CoverImage != null) {
        try {
          // Convert Image to bytes (PNG format) using encodePng from image package
          final imageBytes = img.encodePng(epub.CoverImage!);
          if (imageBytes.isNotEmpty) {
            coverPath = await _saveCoverImage(imageBytes, bookId, 'png');
            if (coverPath != null) {
              return coverPath;
            }
          }
        } catch (e) {
          debugPrint('Error extracting cover from CoverImage: $e');
        }
      }
      
      // Method 2: Look for cover image in Content.Images
      if (epub.Content?.Images != null && epub.Content!.Images!.isNotEmpty) {
        // Try to find cover image by common names
        final coverNames = ['cover', 'Cover', 'COVER', 'cover.jpg', 'cover.png', 'cover.jpeg', 'cover.webp'];
        
        for (final imageEntry in epub.Content!.Images!.entries) {
          final imageKey = imageEntry.key.toLowerCase();
          if (coverNames.any((name) => imageKey.contains(name.toLowerCase()))) {
            try {
              final imageFile = imageEntry.value;
              final imageData = imageFile.Content;
              if (imageData != null && imageData.isNotEmpty) {
                // Determine extension from file name or content
                String? extension;
                if (imageKey.contains('.png')) {
                  extension = 'png';
                } else if (imageKey.contains('.jpg') || imageKey.contains('.jpeg')) {
                  extension = 'jpg';
                } else if (imageKey.contains('.webp')) {
                  extension = 'webp';
                }
                coverPath = await _saveCoverImage(imageData, bookId, extension);
                if (coverPath != null) {
                  return coverPath;
                }
              }
            } catch (e) {
              debugPrint('Error extracting cover from images: $e');
              continue;
            }
          }
        }
        
        // If no cover found by name, try the first image
        if (coverPath == null && epub.Content!.Images!.isNotEmpty) {
          try {
            final firstImageFile = epub.Content!.Images!.values.first;
            final imageData = firstImageFile.Content;
            if (imageData != null && imageData.isNotEmpty) {
              // Determine extension from file name
              final firstImageKey = epub.Content!.Images!.keys.first.toLowerCase();
              String? extension;
              if (firstImageKey.contains('.png')) {
                extension = 'png';
              } else if (firstImageKey.contains('.jpg') || firstImageKey.contains('.jpeg')) {
                extension = 'jpg';
              } else if (firstImageKey.contains('.webp')) {
                extension = 'webp';
              }
              coverPath = await _saveCoverImage(Uint8List.fromList(imageData), bookId, extension);
              if (coverPath != null) {
                return coverPath;
              }
            }
          } catch (e) {
            debugPrint('Error extracting first image as cover: $e');
          }
        }
      }
      
      return coverPath;
    } catch (e) {
      debugPrint('Error extracting cover image: $e');
      return null;
    }
  }

  /// Save cover image to disk
  Future<String?> _saveCoverImage(List<int> imageData, String bookId, String? preferredExtension) async {
    try {
      final booksDir = await getBooksDirectory();
      final coversDir = Directory('$booksDir/covers');
      if (!await coversDir.exists()) {
        await coversDir.create(recursive: true);
      }
      
      // Determine file extension from image data or preferred extension
      String extension = preferredExtension ?? 'jpg';
      if (preferredExtension == null && imageData.length >= 4) {
        // Check for PNG signature
        if (imageData[0] == 0x89 && imageData[1] == 0x50 && imageData[2] == 0x4E && imageData[3] == 0x47) {
          extension = 'png';
        }
        // Check for JPEG signature
        else if (imageData[0] == 0xFF && imageData[1] == 0xD8) {
          extension = 'jpg';
        }
        // Check for WebP signature
        else if (imageData.length >= 12 &&
                 imageData[0] == 0x52 && imageData[1] == 0x49 && imageData[2] == 0x46 && imageData[3] == 0x46 &&
                 imageData[8] == 0x57 && imageData[9] == 0x45 && imageData[10] == 0x42 && imageData[11] == 0x50) {
          extension = 'webp';
        }
      }
      
      final coverPath = '$booksDir/covers/$bookId.$extension';
      final coverFile = File(coverPath);
      await coverFile.writeAsBytes(imageData);
      
      return coverPath;
    } catch (e) {
      debugPrint('Error saving cover image: $e');
      return null;
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

  Future<Book?> getBookById(String bookId) async {
    if (bookId.isEmpty) return null;
    final books = await getAllBooks();
    try {
      return books.firstWhere((book) => book.id == bookId);
    } catch (_) {
      return null;
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
      
      // Delete cover image if it exists
      if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty) {
        try {
          final coverFile = File(book.coverImagePath!);
          if (await coverFile.exists()) {
            await coverFile.delete();
          }
        } catch (e) {
          debugPrint('Error deleting cover image: $e');
        }
      }
      
      // Delete reading progress
      await prefs.remove('$_progressKey${book.id}');
      
      // Delete summary and cache data
      try {
        final summaryDbService = SummaryDatabaseService();
        await summaryDbService.deleteBookSummaries(book.id);
      } catch (e) {
        debugPrint('Failed to delete summaries: $e');
      }

      try {
        final apiCacheService = ApiCacheService();
        await apiCacheService.clearCacheForBook(book.id);
      } catch (e) {
        debugPrint('Failed to clear API cache: $e');
      }
    } catch (e) {
      throw Exception('Failed to delete book: $e');
    }
  }
}
