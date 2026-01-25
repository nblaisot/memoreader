import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import '../models/saved_translation.dart';
import '../models/sync_data.dart';
import 'book_service.dart';
import 'saved_translation_database_service.dart';

/// Service for synchronizing data with Google Drive
class GoogleDriveSyncService {
  static const String _syncEnabledKey = 'google_drive_sync_enabled';
  static const String _lastSyncTimeKey = 'google_drive_last_sync_time';
  static const String _accountEmailKey = 'google_drive_account_email';
  
  // File names in Google Drive appDataFolder
  static const String _booksFileName = 'memoreader_books.json';
  static const String _progressFileName = 'memoreader_progress.json';
  static const String _translationsFileName = 'memoreader_translations.json';
  static const String _deletedBooksKey = 'google_drive_deleted_books';
  static const String _booksFolderName = 'books';
  static const String _coversFolderName = 'covers';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'https://www.googleapis.com/auth/drive.appdata',
    ],
  );

  final BookService _bookService = BookService();
  final SavedTranslationDatabaseService _translationService = SavedTranslationDatabaseService();

  drive.DriveApi? _driveApi;
  bool _isAuthenticated = false;

  /// Check if sync is enabled
  Future<bool> isSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncEnabledKey) ?? false;
  }

  /// Enable or disable sync
  Future<void> setSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, enabled);
    if (!enabled) {
      await signOut();
    }
  }

  /// Get last sync time
  Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timeString = prefs.getString(_lastSyncTimeKey);
    if (timeString == null) return null;
    return DateTime.parse(timeString);
  }

  /// Set last sync time
  Future<void> _setLastSyncTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncTimeKey, time.toIso8601String());
  }

  /// Get account email
  Future<String?> getAccountEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accountEmailKey);
  }

  /// Set account email
  Future<void> _setAccountEmail(String? email) async {
    final prefs = await SharedPreferences.getInstance();
    if (email == null) {
      await prefs.remove(_accountEmailKey);
    } else {
      await prefs.setString(_accountEmailKey, email);
    }
  }

  /// Sign in to Google account
  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        return false; // User cancelled
      }

      // Wait a bit for auth headers to be available
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Get auth headers - may need to call signInSilently first
      final currentUser = _googleSignIn.currentUser;
      if (currentUser == null) {
        debugPrint('[DriveSync] Current user is null after sign in');
        return false;
      }

      final authHeaders = await currentUser.authHeaders;
      if (authHeaders.isEmpty) {
        debugPrint('[DriveSync] Failed to get auth headers');
        return false;
      }

      // Create authenticated HTTP client
      // Google Sign-In provides authHeaders that include Authorization header
      // We need to create a client that uses these headers
      final client = _AuthenticatedHttpClient(authHeaders);
      
      _driveApi = drive.DriveApi(client);
      _isAuthenticated = true;
      await _setAccountEmail(account.email);

      debugPrint('[DriveSync] Signed in as ${account.email}');
      return true;
    } catch (e) {
      debugPrint('[DriveSync] Sign in error: $e');
      _isAuthenticated = false;
      return false;
    }
  }

  /// Sign out from Google account
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      _driveApi = null;
      _isAuthenticated = false;
      await _setAccountEmail(null);
      debugPrint('[DriveSync] Signed out');
    } catch (e) {
      debugPrint('[DriveSync] Sign out error: $e');
    }
  }

  /// Check if currently authenticated
  bool get isAuthenticated => _isAuthenticated && _driveApi != null;

  /// Main sync method called on app startup
  Future<void> syncOnStartup() async {
    if (!await isSyncEnabled()) {
      debugPrint('[DriveSync] Sync is disabled');
      return;
    }

    try {
      // Check if already authenticated
      if (!isAuthenticated) {
        final signedIn = await signIn();
        if (!signedIn) {
          debugPrint('[DriveSync] Not signed in, skipping sync');
          return;
        }
      }

      debugPrint('[DriveSync] Starting sync...');
      
      // Download and merge remote data
      await downloadSync();
      
      // Upload local data
      await uploadSync();
      
      await _setLastSyncTime(DateTime.now());
      debugPrint('[DriveSync] Sync completed successfully');
    } catch (e) {
      debugPrint('[DriveSync] Sync error: $e');
      // Don't throw - sync failures shouldn't crash the app
    }
  }

  /// Upload local data to Drive
  Future<void> uploadSync() async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }

    try {
      // Upload books metadata
      await _uploadBooksMetadata();
      
      // Upload reading progress
      await _uploadProgress();
      
      // Upload translations
      await _uploadTranslations();
      
      // Upload EPUB files and covers for books that need syncing
      await _uploadBookFiles();
      
      debugPrint('[DriveSync] Upload completed');
    } catch (e) {
      debugPrint('[DriveSync] Upload error: $e');
      rethrow;
    }
  }

  /// Download and merge remote data from Drive
  Future<void> downloadSync() async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }

    try {
      // Download and merge books
      await _downloadAndMergeBooks();
      
      // Download and merge progress
      await _downloadAndMergeProgress();
      
      // Download and merge translations
      await _downloadAndMergeTranslations();
      
      // Download EPUB files and covers for books that need them
      await _downloadBookFiles();
      
      debugPrint('[DriveSync] Download completed');
    } catch (e) {
      debugPrint('[DriveSync] Download error: $e');
      rethrow;
    }
  }

  // Private helper methods

  /// Get locally tracked deleted books
  Future<Map<String, DateTime>> _getDeletedBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final deletedJson = prefs.getString(_deletedBooksKey);
    if (deletedJson == null) return {};
    
    final deletedMap = jsonDecode(deletedJson) as Map<String, dynamic>;
    return deletedMap.map(
      (key, value) => MapEntry(key, DateTime.parse(value as String)),
    );
  }

  /// Track a book deletion
  Future<void> _trackBookDeletion(String bookId) async {
    final deletedBooks = await _getDeletedBooks();
    deletedBooks[bookId] = DateTime.now();
    
    final prefs = await SharedPreferences.getInstance();
    final deletedJson = jsonEncode(
      deletedBooks.map((key, value) => MapEntry(key, value.toIso8601String())),
    );
    await prefs.setString(_deletedBooksKey, deletedJson);
  }

  /// Remove a book from deletion tracking (if it was re-added)
  Future<void> _untrackBookDeletion(String bookId) async {
    final deletedBooks = await _getDeletedBooks();
    deletedBooks.remove(bookId);
    
    final prefs = await SharedPreferences.getInstance();
    if (deletedBooks.isEmpty) {
      await prefs.remove(_deletedBooksKey);
    } else {
      final deletedJson = jsonEncode(
        deletedBooks.map((key, value) => MapEntry(key, value.toIso8601String())),
      );
      await prefs.setString(_deletedBooksKey, deletedJson);
    }
  }

  /// Upload books metadata JSON file
  Future<void> _uploadBooksMetadata() async {
    final books = await _bookService.getAllBooks();
    final deletedBooks = await _getDeletedBooks();
    
    // Remove books from deletion tracking if they were re-added (dateAdded is newer than deletion)
    final now = DateTime.now();
    final booksToRemoveFromDeletion = <String>[];
    for (final book in books) {
      final deletionTime = deletedBooks[book.id];
      if (deletionTime != null && book.dateAdded.isAfter(deletionTime)) {
        // Book was re-added after deletion - remove from deletion tracking
        booksToRemoveFromDeletion.add(book.id);
      }
    }
    for (final bookId in booksToRemoveFromDeletion) {
      deletedBooks.remove(bookId);
      await _untrackBookDeletion(bookId);
      debugPrint('[DriveSync] Removed book $bookId from deletion tracking (was re-added)');
    }
    
    // Clean up old deletions (older than 30 days) to prevent unbounded growth
    final cutoffDate = now.subtract(const Duration(days: 30));
    deletedBooks.removeWhere((key, value) => value.isBefore(cutoffDate));
    
    final syncData = SyncBooksData(
      books: books,
      deletedBooks: deletedBooks,
      lastModified: now,
    );

    final jsonBytes = utf8.encode(jsonEncode(syncData.toJson()));
    await _uploadFile(_booksFileName, jsonBytes, 'application/json');
  }
  
  /// Called when a book is deleted to track it for sync
  Future<void> onBookDeleted(String bookId) async {
    await _trackBookDeletion(bookId);
    debugPrint('[DriveSync] Tracked deletion of book $bookId');
  }

  /// Called when a book is re-added to remove it from deletion tracking
  Future<void> onBookReAdded(String bookId) async {
    final deletedBooks = await _getDeletedBooks();
    if (deletedBooks.containsKey(bookId)) {
      await _untrackBookDeletion(bookId);
      debugPrint('[DriveSync] Removed book $bookId from deletion tracking (was re-added)');
    }
  }

  /// Upload reading progress JSON file
  Future<void> _uploadProgress() async {
    final books = await _bookService.getAllBooks();
    final progressMap = <String, ReadingProgress>{};

    for (final book in books) {
      final progress = await _bookService.getReadingProgress(book.id);
      if (progress != null) {
        progressMap[book.id] = progress;
      }
    }

    final syncData = SyncProgressData(
      progress: progressMap,
      lastModified: DateTime.now(),
    );

    final jsonBytes = utf8.encode(jsonEncode(syncData.toJson()));
    await _uploadFile(_progressFileName, jsonBytes, 'application/json');
  }

  /// Upload translations JSON file
  Future<void> _uploadTranslations() async {
    final books = await _bookService.getAllBooks();
    final allTranslations = <SavedTranslation>[];

    for (final book in books) {
      final translations = await _translationService.getTranslations(book.id);
      allTranslations.addAll(translations);
    }

    final syncData = SyncTranslationsData(
      translations: allTranslations,
      lastModified: DateTime.now(),
    );

    final jsonBytes = utf8.encode(jsonEncode(syncData.toJson()));
    await _uploadFile(_translationsFileName, jsonBytes, 'application/json');
  }

  /// Upload EPUB files and cover images
  Future<void> _uploadBookFiles() async {
    final books = await _bookService.getAllBooks();
    final deletedBooks = await _getDeletedBooks();

    for (final book in books) {
      try {
        // Skip if book is marked as deleted
        if (deletedBooks.containsKey(book.id)) {
          continue;
        }
        
        // Upload EPUB file
        final epubFile = File(book.filePath);
        if (await epubFile.exists()) {
          final epubBytes = await epubFile.readAsBytes();
          final filePath = '$_booksFolderName/${book.id}.epub';
          await _uploadFile(filePath, epubBytes, 'application/epub+zip');
        }

        // Upload cover image if exists
        if (book.coverImagePath != null) {
          final coverFile = File(book.coverImagePath!);
          if (await coverFile.exists()) {
            final coverBytes = await coverFile.readAsBytes();
            final extension = book.coverImagePath!.split('.').last;
            final filePath = '$_coversFolderName/${book.id}.$extension';
            final mimeType = _getImageMimeType(extension);
            await _uploadFile(filePath, coverBytes, mimeType);
          }
        }
      } catch (e) {
        debugPrint('[DriveSync] Error uploading files for book ${book.id}: $e');
        // Continue with next book
      }
    }
    
    // Delete EPUB files and covers from Drive for deleted books
    for (final bookId in deletedBooks.keys) {
      try {
        // Try to delete EPUB file
        final epubPath = '$_booksFolderName/$bookId.epub';
        await _deleteFile(epubPath);
        
        // Try to delete cover images with different extensions
        for (final ext in ['png', 'jpg', 'jpeg', 'webp']) {
          final coverPath = '$_coversFolderName/$bookId.$ext';
          await _deleteFile(coverPath);
        }
      } catch (e) {
        debugPrint('[DriveSync] Error deleting files for deleted book $bookId: $e');
        // Continue - file might not exist
      }
    }
  }

  /// Download and merge books
  Future<void> _downloadAndMergeBooks() async {
    try {
      final jsonBytes = await _downloadFile(_booksFileName);
      if (jsonBytes == null) {
        debugPrint('[DriveSync] No books file found in Drive');
        return;
      }

      final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
      final remoteData = SyncBooksData.fromJson(
        json,
        booksDirectory: await _bookService.getBooksDirectory(),
        coversDirectory: await _bookService.getCoversDirectory(),
      );

      final localBooks = await _bookService.getAllBooks();
      final localBooksMap = {for (var b in localBooks) b.id: b};
      final localDeletedBooks = await _getDeletedBooks();

      // Handle remote deletions - delete books that are marked as deleted in Drive
      for (final entry in remoteData.deletedBooks.entries) {
        final bookId = entry.key;
        final remoteDeletionTime = entry.value;
        final localDeletionTime = localDeletedBooks[bookId];
        
        // If book exists locally and wasn't deleted locally, or was deleted later remotely
        if (localBooksMap.containsKey(bookId)) {
          if (localDeletionTime == null || remoteDeletionTime.isAfter(localDeletionTime)) {
            // Remote deletion is newer or local wasn't deleted - delete locally
            final book = localBooksMap[bookId]!;
            await _bookService.deleteBook(book);
            await _trackBookDeletion(bookId);
            debugPrint('[DriveSync] Deleted book ${book.title} (ID: $bookId) due to remote deletion');
          }
        } else if (localDeletionTime == null) {
          // Book doesn't exist locally and wasn't deleted locally - track the deletion
          await _trackBookDeletion(bookId);
        }
      }

      // Merge books - only add books that aren't marked as deleted
      for (final remoteBook in remoteData.books) {
        final remoteDeletionTime = remoteData.deletedBooks[remoteBook.id];
        final localBook = localBooksMap[remoteBook.id];
        final localDeletionTime = localDeletedBooks[remoteBook.id];
        
        // If book was deleted but re-added (dateAdded is newer than deletion), remove from deletion tracking
        if (remoteDeletionTime != null && remoteBook.dateAdded.isAfter(remoteDeletionTime)) {
          // Book was re-added after deletion - remove from deletion tracking
          await _untrackBookDeletion(remoteBook.id);
          debugPrint('[DriveSync] Book ${remoteBook.id} was re-added, removed from deletion tracking');
        }
        
        // Skip if this book is marked as deleted remotely (and deletion is newer than book)
        if (remoteDeletionTime != null && remoteDeletionTime.isAfter(remoteBook.dateAdded)) {
          // Book was deleted after it was added - don't restore it
          // But if we have it locally and it wasn't deleted locally, delete it
          if (localBook != null && localDeletionTime == null) {
            await _bookService.deleteBook(localBook);
            await _trackBookDeletion(remoteBook.id);
            debugPrint('[DriveSync] Deleted local book ${localBook.title} (ID: ${localBook.id}) due to remote deletion');
          }
          continue;
        }
        
        if (localBook == null) {
          // Book exists in Drive but not locally
          // Only add if it wasn't deleted locally, or if remote book is newer than local deletion
          if (localDeletionTime == null) {
            // Never deleted locally - add it
            await _bookService.updateBook(remoteBook);
            debugPrint('[DriveSync] Added book ${remoteBook.title} (ID: ${remoteBook.id}) from Drive');
          } else if (remoteDeletionTime == null && remoteBook.dateAdded.isAfter(localDeletionTime)) {
            // Was deleted locally, but remote has a newer version - restore it
            await _bookService.updateBook(remoteBook);
            await _untrackBookDeletion(remoteBook.id);
            debugPrint('[DriveSync] Restored book ${remoteBook.title} (ID: ${remoteBook.id}) from Drive');
          }
          // Otherwise, keep it deleted (local deletion is newer)
        } else {
          // Book exists in both - keep the one with newer dateAdded
          if (remoteBook.dateAdded.isAfter(localBook.dateAdded)) {
            await _bookService.updateBook(remoteBook);
          }
          // If book exists locally and wasn't deleted, remove from deletion tracking (it was re-added)
          if (localDeletionTime != null) {
            await _untrackBookDeletion(remoteBook.id);
            debugPrint('[DriveSync] Book ${remoteBook.id} exists locally, removed from deletion tracking');
          }
        }
      }

      // Handle local deletions - upload deletion tracking for books deleted locally
      for (final entry in localDeletedBooks.entries) {
        final bookId = entry.key;
        final localDeletionTime = entry.value;
        final remoteDeletionTime = remoteData.deletedBooks[bookId];
        
        // If book exists in Drive but wasn't deleted there, or was deleted later locally
        if (remoteData.books.any((b) => b.id == bookId)) {
          if (remoteDeletionTime == null || localDeletionTime.isAfter(remoteDeletionTime)) {
            // Local deletion is newer - will be uploaded in next sync
            debugPrint('[DriveSync] Local deletion of book $bookId will be synced');
          }
        }
      }
    } catch (e) {
      debugPrint('[DriveSync] Error downloading books: $e');
      // Don't throw - continue with other sync operations
    }
  }

  /// Download and merge progress
  Future<void> _downloadAndMergeProgress() async {
    try {
      final jsonBytes = await _downloadFile(_progressFileName);
      if (jsonBytes == null) {
        debugPrint('[DriveSync] No progress file found in Drive');
        return;
      }

      final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
      final remoteData = SyncProgressData.fromJson(json);

      // Merge progress - keep the one with most recent lastRead
      for (final entry in remoteData.progress.entries) {
        final localProgress = await _bookService.getReadingProgress(entry.key);
        
        if (localProgress == null) {
          // Progress exists in Drive but not locally
          await _bookService.saveReadingProgress(entry.value);
        } else {
          // Progress exists in both - keep the one with newer lastRead
          if (entry.value.lastRead.isAfter(localProgress.lastRead)) {
            await _bookService.saveReadingProgress(entry.value);
          }
        }
      }
    } catch (e) {
      debugPrint('[DriveSync] Error downloading progress: $e');
      // Don't throw - continue with other sync operations
    }
  }

  /// Download and merge translations
  Future<void> _downloadAndMergeTranslations() async {
    try {
      final jsonBytes = await _downloadFile(_translationsFileName);
      if (jsonBytes == null) {
        debugPrint('[DriveSync] No translations file found in Drive');
        return;
      }

      final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
      final remoteData = SyncTranslationsData.fromJson(json);

      // Get all local translations
      final books = await _bookService.getAllBooks();
      final localTranslations = <SavedTranslation>[];
      for (final book in books) {
        localTranslations.addAll(await _translationService.getTranslations(book.id));
      }
      final localTranslationsMap = {for (var t in localTranslations) t.id: t};

      // Merge translations
      for (final remoteTranslation in remoteData.translations) {
        final localTranslation = remoteTranslation.id != null 
            ? localTranslationsMap[remoteTranslation.id] 
            : null;
        
        if (localTranslation == null) {
          // Translation exists in Drive but not locally - add it
          await _translationService.saveTranslation(remoteTranslation);
        } else {
          // Translation exists in both - keep the one with newer createdAt
          if (remoteTranslation.createdAt.isAfter(localTranslation.createdAt)) {
            await _translationService.saveTranslation(remoteTranslation);
          }
        }
      }
    } catch (e) {
      debugPrint('[DriveSync] Error downloading translations: $e');
      // Don't throw - continue with other sync operations
    }
  }

  /// Download EPUB files and cover images
  Future<void> _downloadBookFiles() async {
    final books = await _bookService.getAllBooks();

    for (final book in books) {
      try {
        // Download EPUB file if it doesn't exist locally
        final epubFile = File(book.filePath);
        if (!await epubFile.exists()) {
          final filePath = '$_booksFolderName/${book.id}.epub';
          final epubBytes = await _downloadFile(filePath);
          if (epubBytes != null) {
            // Ensure directory exists
            await epubFile.parent.create(recursive: true);
            await epubFile.writeAsBytes(epubBytes);
            debugPrint('[DriveSync] Downloaded EPUB for book ${book.id}');
          }
        }

        // Download cover image if it doesn't exist locally
        if (book.coverImagePath == null || !await File(book.coverImagePath!).exists()) {
          // Try different image extensions
          for (final ext in ['png', 'jpg', 'jpeg', 'webp']) {
            final filePath = '$_coversFolderName/${book.id}.$ext';
            final coverBytes = await _downloadFile(filePath);
            if (coverBytes != null) {
              final coversDir = await _bookService.getCoversDirectory();
              final coverFile = File('$coversDir/${book.id}.$ext');
              await coverFile.writeAsBytes(coverBytes);
              
              // Update book with cover path
              final updatedBook = Book(
                id: book.id,
                title: book.title,
                author: book.author,
                coverImagePath: coverFile.path,
                filePath: book.filePath,
                dateAdded: book.dateAdded,
                isValid: book.isValid,
              );
              await _bookService.updateBook(updatedBook);
              debugPrint('[DriveSync] Downloaded cover for book ${book.id}');
              break;
            }
          }
        }
      } catch (e) {
        debugPrint('[DriveSync] Error downloading files for book ${book.id}: $e');
        // Continue with next book
      }
    }
  }

  /// Upload a file to Google Drive appDataFolder
  Future<void> _uploadFile(String fileName, List<int> fileBytes, String mimeType) async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }

    try {
      // Check if file already exists
      final existingFile = await _findFile(fileName);
      
      final media = drive.Media(
        Stream.value(fileBytes),
        fileBytes.length,
        contentType: mimeType,
      );

      if (existingFile != null) {
        // Update existing file
        await _driveApi!.files.update(
          drive.File()..name = fileName,
          existingFile.id!,
          uploadMedia: media,
        );
        debugPrint('[DriveSync] Updated file: $fileName');
      } else {
        // Create new file
        await _driveApi!.files.create(
          drive.File()
            ..name = fileName
            ..parents = ['appDataFolder'],
          uploadMedia: media,
        );
        debugPrint('[DriveSync] Created file: $fileName');
      }
    } catch (e) {
      debugPrint('[DriveSync] Error uploading file $fileName: $e');
      rethrow;
    }
  }

  /// Download a file from Google Drive appDataFolder
  Future<List<int>?> _downloadFile(String fileName) async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }

    try {
      final file = await _findFile(fileName);
      if (file == null) {
        return null;
      }

      final response = await _driveApi!.files.get(
        file.id!,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
      }

      debugPrint('[DriveSync] Downloaded file: $fileName (${bytes.length} bytes)');
      return bytes;
    } catch (e) {
      debugPrint('[DriveSync] Error downloading file $fileName: $e');
      return null;
    }
  }

  /// Find a file in appDataFolder by name
  Future<drive.File?> _findFile(String fileName) async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }

    try {
      final response = await _driveApi!.files.list(
        q: "name='$fileName' and 'appDataFolder' in parents",
        spaces: 'appDataFolder',
      );

      if (response.files != null && response.files!.isNotEmpty) {
        return response.files!.first;
      }
      return null;
    } catch (e) {
      debugPrint('[DriveSync] Error finding file $fileName: $e');
      return null;
    }
  }

  /// Delete a file from Google Drive appDataFolder
  Future<void> _deleteFile(String fileName) async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }

    try {
      final file = await _findFile(fileName);
      if (file != null && file.id != null) {
        await _driveApi!.files.delete(file.id!);
        debugPrint('[DriveSync] Deleted file: $fileName');
      }
    } catch (e) {
      debugPrint('[DriveSync] Error deleting file $fileName: $e');
      // Don't throw - file might not exist
    }
  }

  /// Get MIME type for image extension
  String _getImageMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }
}

/// HTTP client wrapper that adds authentication headers to requests
class _AuthenticatedHttpClient extends http.BaseClient {
  final Map<String, String> _authHeaders;
  final http.Client _client = http.Client();

  _AuthenticatedHttpClient(this._authHeaders);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Add auth headers to the request
    _authHeaders.forEach((key, value) {
      request.headers[key] = value;
    });
    return _client.send(request);
  }

  @override
  void close() {
    _client.close();
  }
}
