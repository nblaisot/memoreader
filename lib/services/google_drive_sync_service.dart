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
import 'summary_config_service.dart';
import 'drive_api_keys_cipher.dart';
import 'drive_sync_merge.dart';
import 'drive_sync_secrets_service.dart';

/// Status of an ongoing or completed sync cycle.
enum SyncStatus { idle, syncing, success, error }

/// Why encrypted API keys from Drive could not be merged (for localized UI).
enum DriveApiKeysSyncIssue {
  missingPassphrase,
  decryptFailed,
  unreadableRemote,
}

/// Service for synchronising data with Google Drive.
///
/// This is a singleton — every call to [GoogleDriveSyncService()] returns the
/// same instance, so authenticated state (the [DriveApi]) is shared across all
/// callers (main.dart startup sync, SettingsScreen, LibraryScreen, …).
class GoogleDriveSyncService {
  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------

  static final GoogleDriveSyncService _instance =
      GoogleDriveSyncService._internal();

  factory GoogleDriveSyncService() => _instance;

  GoogleDriveSyncService._internal();

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  static const String _syncEnabledKey = 'google_drive_sync_enabled';
  static const String _lastSyncTimeKey = 'google_drive_last_sync_time';
  static const String _accountEmailKey = 'google_drive_account_email';
  static const String _deletedBooksKey = 'google_drive_deleted_books';
  static const String _pendingDriveBlobDeletesKey =
      'google_drive_pending_blob_deletes';

  static const String _booksFileName = 'memoreader_books.json';
  static const String _progressFileName = 'memoreader_progress.json';
  static const String _translationsFileName = 'memoreader_translations.json';
  static const String _apiKeysFileName = 'memoreader_api_keys.json';
  static const String _booksFolderName = 'books';
  static const String _coversFolderName = 'covers';

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.appdata'],
  );

  final BookService _bookService = BookService();
  final SavedTranslationDatabaseService _translationService =
      SavedTranslationDatabaseService();

  drive.DriveApi? _driveApi;
  bool _isAuthenticated = false;

  /// Guards against concurrent sync runs.
  bool _isSyncing = false;

  /// Set to true if any download/merge step encountered an error.
  /// Checked before running the upload phase to avoid overwriting
  /// remote data with potentially incomplete local state.
  bool _downloadHadErrors = false;

  /// Observable sync status so the UI can show global toasts.
  final ValueNotifier<SyncStatus> syncStatus =
      ValueNotifier(SyncStatus.idle);

  /// Non-null when encrypted API keys on Drive could not be applied (missing
  /// or wrong passphrase). Cleared when merge succeeds or the remote file is
  /// absent / not encrypted.
  final ValueNotifier<DriveApiKeysSyncIssue?> apiKeysSyncIssue =
      ValueNotifier(null);

  /// Book IDs whose EPUB files are known to exist on Drive.
  /// Populated during sync by listing the appDataFolder, and updated
  /// immediately after a successful [uploadBookToDrive].
  final Set<String> _uploadedBookIds = {};

  /// Whether [bookId]'s EPUB file is already on Drive.
  bool isBookUploadedToDrive(String bookId) =>
      _uploadedBookIds.contains(bookId);

  // ---------------------------------------------------------------------------
  // Auth — public
  // ---------------------------------------------------------------------------

  bool get isAuthenticated => _isAuthenticated && _driveApi != null;

  /// Interactive sign-in — must be called from a user-initiated action because
  /// it shows the Google account-picker UI.
  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return false; // user cancelled

      _driveApi = drive.DriveApi(_AuthenticatedHttpClient(_googleSignIn));
      _isAuthenticated = true;
      await _setAccountEmail(account.email);
      debugPrint('[DriveSync] Signed in as ${account.email}');
      return true;
    } catch (e) {
      debugPrint('[DriveSync] Sign-in error: $e');
      _isAuthenticated = false;
      return false;
    }
  }

  /// Sign out and clear local auth state.
  ///
  /// Does **not** clear the Drive sync passphrase or encryption preference;
  /// those live in secure storage / SharedPreferences so the user can sign in
  /// again without re-entering secrets.
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      debugPrint('[DriveSync] Sign-out error: $e');
    } finally {
      _driveApi = null;
      _isAuthenticated = false;
      await _setAccountEmail(null);
      debugPrint('[DriveSync] Signed out');
    }
  }

  // ---------------------------------------------------------------------------
  // Auth — private helpers
  // ---------------------------------------------------------------------------

  /// Ensures we have a valid [DriveApi].
  ///
  /// First tries a *silent* sign-in (uses the cached OS session — no UI).
  /// Falls back to the interactive flow only when [interactive] is `true`.
  Future<bool> _ensureAuthenticated({bool interactive = false}) async {
    if (isAuthenticated) return true;

    // Try silent re-authentication (no UI, reuses the stored OS credential).
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        _driveApi = drive.DriveApi(_AuthenticatedHttpClient(_googleSignIn));
        _isAuthenticated = true;
        await _setAccountEmail(account.email);
        debugPrint('[DriveSync] Silently re-authenticated as ${account.email}');
        return true;
      }
    } catch (e) {
      debugPrint('[DriveSync] Silent sign-in failed: $e');
    }

    if (!interactive) {
      debugPrint('[DriveSync] No cached session — skipping background sync');
      return false;
    }

    return signIn();
  }

  // ---------------------------------------------------------------------------
  // SharedPreferences helpers
  // ---------------------------------------------------------------------------

  Future<bool> isSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncEnabledKey) ?? false;
  }

  Future<void> setSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, enabled);
    if (!enabled) await signOut();
  }

  Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_lastSyncTimeKey);
    return s == null ? null : DateTime.parse(s);
  }

  Future<void> _setLastSyncTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncTimeKey, time.toIso8601String());
  }

  Future<void> _clearLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSyncTimeKey);
  }

  Future<String?> getAccountEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accountEmailKey);
  }

  Future<void> _setAccountEmail(String? email) async {
    final prefs = await SharedPreferences.getInstance();
    if (email == null) {
      await prefs.remove(_accountEmailKey);
    } else {
      await prefs.setString(_accountEmailKey, email);
    }
  }

  // ---------------------------------------------------------------------------
  // Deletion tombstone helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, DateTime>> _getDeletedBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_deletedBooksKey);
    if (json == null) return {};
    return (jsonDecode(json) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, DateTime.parse(v as String)));
  }

  Future<void> _saveDeletedBooks(Map<String, DateTime> map) async {
    final prefs = await SharedPreferences.getInstance();
    if (map.isEmpty) {
      await prefs.remove(_deletedBooksKey);
    } else {
      await prefs.setString(
        _deletedBooksKey,
        jsonEncode(map.map((k, v) => MapEntry(k, v.toIso8601String()))),
      );
    }
  }

  Future<void> _trackBookDeletion(String bookId) async {
    final deleted = await _getDeletedBooks();
    deleted[bookId] = DateTime.now();
    await _saveDeletedBooks(deleted);
  }

  Future<void> _untrackBookDeletion(String bookId) async {
    final deleted = await _getDeletedBooks();
    deleted.remove(bookId);
    await _saveDeletedBooks(deleted);
  }

  Future<List<String>> _getPendingDriveBlobDeletes() async {
    final prefs = await SharedPreferences.getInstance();
    return List<String>.from(
      prefs.getStringList(_pendingDriveBlobDeletesKey) ?? const [],
    );
  }

  Future<void> _setPendingDriveBlobDeletes(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    if (ids.isEmpty) {
      await prefs.remove(_pendingDriveBlobDeletesKey);
    } else {
      await prefs.setStringList(_pendingDriveBlobDeletesKey, ids);
    }
  }

  Future<void> _enqueueDriveBlobDelete(String bookId) async {
    final pending = await _getPendingDriveBlobDeletes();
    if (!pending.contains(bookId)) {
      pending.add(bookId);
      await _setPendingDriveBlobDeletes(pending);
      debugPrint('[DriveSync] Queued remote blob delete for $bookId');
    }
  }

  Future<void> _removePendingDriveBlobDelete(String bookId) async {
    final pending = await _getPendingDriveBlobDeletes();
    if (pending.remove(bookId)) {
      await _setPendingDriveBlobDeletes(pending);
    }
  }

  /// Deletes `books/{id}.epub` and `covers/{id}.*` from Drive when present.
  Future<void> _deleteDriveBlobsForBook(String bookId) async {
    if (!isAuthenticated) return;
    final names = <String>[
      '$_booksFolderName/$bookId.epub',
      for (final ext in ['png', 'jpg', 'jpeg', 'webp'])
        '$_coversFolderName/$bookId.$ext',
    ];
    for (final name in names) {
      try {
        final f = await _findFile(name);
        final id = f?.id;
        if (id == null || id.isEmpty) continue;
        await _driveApi!.files.delete(id);
        debugPrint('[DriveSync] Deleted remote file $name');
      } catch (e) {
        debugPrint('[DriveSync] Failed to delete remote $name: $e');
      }
    }
    _uploadedBookIds.remove(bookId);
  }

  /// Removes queued remote EPUB/cover files. Safe to call often; no-ops when
  /// not signed in (queue is kept until [uploadSync] or the next delete).
  Future<void> processPendingDriveBlobDeletes() async {
    if (!isAuthenticated) return;
    final pending = await _getPendingDriveBlobDeletes();
    if (pending.isEmpty) return;
    final stillPending = <String>[];
    for (final bookId in pending) {
      try {
        await _deleteDriveBlobsForBook(bookId);
      } catch (e) {
        debugPrint('[DriveSync] Blob delete failed for $bookId: $e');
        stillPending.add(bookId);
      }
    }
    await _setPendingDriveBlobDeletes(stillPending);
  }

  /// Call when a book is deleted locally so the deletion is propagated on next sync.
  ///
  /// Returns `true` if signed in to Drive and the pending blob delete queue was
  /// processed (remote EPUB/cover removal attempted). Returns `false` if offline
  /// from Drive; cleanup runs on the next successful [uploadSync] or sign-in.
  Future<bool> onBookDeleted(String bookId) async {
    await _trackBookDeletion(bookId);
    await _enqueueDriveBlobDelete(bookId);
    if (!isAuthenticated) {
      debugPrint('[DriveSync] Tracked deletion of book $bookId '
          '(Drive blobs queued until sign-in)');
      return false;
    }
    await processPendingDriveBlobDeletes();
    debugPrint('[DriveSync] Tracked deletion of book $bookId '
        '(processed Drive blob queue)');
    return true;
  }

  /// Call when a previously-deleted book is re-imported.
  Future<void> onBookReAdded(String bookId) async {
    await _untrackBookDeletion(bookId);
    await _removePendingDriveBlobDelete(bookId);
    debugPrint('[DriveSync] Cleared deletion tracking for re-added book $bookId');
  }

  // ---------------------------------------------------------------------------
  // Sync entry points
  // ---------------------------------------------------------------------------

  /// Called on app startup.
  ///
  /// Uses silent authentication (no UI).  If the user has never signed in, or
  /// revoked access, this is a no-op — the app continues normally.
  Future<void> syncOnStartup() async {
    if (!await isSyncEnabled()) {
      debugPrint('[DriveSync] Sync disabled — skipping');
      return;
    }

    if (_isSyncing) {
      debugPrint('[DriveSync] Sync already in progress — skipping');
      return;
    }

    _isSyncing = true;
    _downloadHadErrors = false;
    apiKeysSyncIssue.value = null;
    syncStatus.value = SyncStatus.syncing;
    try {
      final ok = await _ensureAuthenticated(interactive: false);
      if (!ok) {
        syncStatus.value = SyncStatus.idle;
        return;
      }

      debugPrint('[DriveSync] Starting sync…');
      await downloadSync();
      await _refreshUploadedBookIds();

      if (_downloadHadErrors) {
        debugPrint('[DriveSync] Download had errors — skipping upload phase');
      } else {
        await uploadSync();
      }

      await _setLastSyncTime(DateTime.now());
      syncStatus.value = SyncStatus.success;
      debugPrint('[DriveSync] Sync completed successfully');
    } catch (e) {
      debugPrint('[DriveSync] Sync error: $e');
      syncStatus.value = SyncStatus.error;
    } finally {
      _isSyncing = false;
    }
  }

  /// Clears the queue of pending per-book Drive blob deletes (EPUB/cover paths).
  ///
  /// Call after [resetRemoteSyncData], since the remote folder is empty; avoids
  /// redundant delete attempts on the next sync.
  Future<void> clearPendingDriveBlobDeletes() async {
    await _setPendingDriveBlobDeletes([]);
  }

  /// Deletes every file in the Drive [appDataFolder] for this app (all remote
  /// sync blobs: JSON, EPUBs, covers, etc.). Does **not** remove books or
  /// progress stored on this device, and does **not** clear the local sync
  /// passphrase (so the user can upload again with the same passphrase).
  /// Clears the pending per-book blob delete queue.
  Future<void> resetRemoteSyncData() async {
    if (!isAuthenticated) {
      throw Exception('Not authenticated');
    }
    if (_isSyncing) {
      throw Exception('Sync in progress — try again when it finishes');
    }

    var totalListed = 0;
    var totalDeleted = 0;
    String? pageToken;

    do {
      final response = await _driveApi!.files.list(
        q: "'appDataFolder' in parents",
        spaces: 'appDataFolder',
        pageSize: 1000,
        pageToken: pageToken,
        $fields: 'nextPageToken, files(id, name)',
      );

      final files = response.files ?? <drive.File>[];
      totalListed += files.length;

      for (final f in files) {
        final id = f.id;
        if (id == null || id.isEmpty) continue;
        try {
          await _driveApi!.files.delete(id);
          totalDeleted++;
          debugPrint('[DriveSync] Deleted remote file ${f.name ?? id}');
        } catch (e) {
          debugPrint(
              '[DriveSync] Failed to delete remote file ${f.name ?? id}: $e');
        }
      }

      pageToken = response.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);

    _uploadedBookIds.clear();
    await _clearLastSyncTime();
    await clearPendingDriveBlobDeletes();
    debugPrint(
        '[DriveSync] resetRemoteSyncData done: listed $totalListed, '
        'deleted $totalDeleted');
  }

  /// Download and merge remote Drive data into local storage.
  ///
  /// Book metadata (title, author, progress, translations) is synced
  /// automatically.  EPUB files are NOT downloaded automatically — the user
  /// downloads them on demand via [downloadBookFromDrive].
  Future<void> downloadSync() async {
    if (!isAuthenticated) throw Exception('Not authenticated');
    await _downloadAndMergeBooks();
    await _downloadAndMergeProgress();
    await _downloadAndMergeTranslations();
    await _downloadAndMergeApiKeys();
    debugPrint('[DriveSync] Download phase complete');
  }

  /// Upload local data to Drive.
  ///
  /// Book metadata is synced automatically.  EPUB files are NOT uploaded
  /// automatically — the user uploads them on demand via [uploadBookToDrive].
  Future<void> uploadSync() async {
    if (!isAuthenticated) throw Exception('Not authenticated');
    await processPendingDriveBlobDeletes();
    await _uploadBooksMetadata();
    await _uploadProgress();
    await _uploadTranslations();
    await _uploadApiKeys();
    debugPrint('[DriveSync] Upload phase complete');
  }

  // ---------------------------------------------------------------------------
  // Per-book on-demand file transfer (user-initiated)
  // ---------------------------------------------------------------------------

  /// Upload a single book's EPUB and cover to Drive.
  ///
  /// Called manually from the library when the user chooses "Upload to Drive".
  /// Overwrites any existing Drive copy so the latest version is always stored.
  Future<void> uploadBookToDrive(Book book) async {
    if (!isAuthenticated) throw Exception('Not authenticated');

    final epubFile = File(book.filePath);
    if (await epubFile.exists()) {
      await _uploadFile(
        '$_booksFolderName/${book.id}.epub',
        await epubFile.readAsBytes(),
        'application/epub+zip',
      );
      debugPrint('[DriveSync] Uploaded EPUB for "${book.title}"');
      _uploadedBookIds.add(book.id);
    }

    if (book.coverImagePath != null) {
      final coverFile = File(book.coverImagePath!);
      if (await coverFile.exists()) {
        final ext = book.coverImagePath!.split('.').last;
        await _uploadFile(
          '$_coversFolderName/${book.id}.$ext',
          await coverFile.readAsBytes(),
          _getImageMimeType(ext),
        );
        debugPrint('[DriveSync] Uploaded cover for "${book.title}"');
      }
    }

    // Keep the books metadata in sync so other devices know this book exists.
    await _uploadBooksMetadata();
  }

  /// Download a single book's EPUB from Drive.
  ///
  /// Called when the user taps a grayed-out (file-missing) book and confirms
  /// the download dialog.  Returns `true` if the file was found and written,
  /// or `false` if the EPUB does not exist on Drive.
  ///
  /// Also pulls `covers/{id}.{ext}` when present (matching [uploadBookToDrive]),
  /// or extracts a cover from the EPUB as a fallback.
  Future<bool> downloadBookFromDrive(Book book) async {
    if (!isAuthenticated) throw Exception('Not authenticated');

    final bytes = await _downloadFile('$_booksFolderName/${book.id}.epub');
    if (bytes == null) {
      debugPrint('[DriveSync] EPUB not found on Drive for "${book.title}"');
      return false;
    }

    final epubFile = File(book.filePath);
    await epubFile.parent.create(recursive: true);
    await epubFile.writeAsBytes(bytes);
    debugPrint('[DriveSync] Downloaded EPUB for "${book.title}"');

    // Persist isValid: true immediately so the library screen shows the book
    // as valid on the next _loadBooks() without waiting for _validateBookFile.
    final validBook = Book(
      id: book.id,
      title: book.title,
      author: book.author,
      coverImagePath: book.coverImagePath,
      filePath: book.filePath,
      dateAdded: book.dateAdded,
      isValid: true,
    );
    await _bookService.addOrUpdateBook(validBook);

    await _downloadOrExtractCoverAfterEpub(validBook);
    return true;
  }

  static bool _isPlausibleImageExt(String ext) {
    final e = ext.toLowerCase();
    if (e.length < 2 || e.length > 5) return false;
    return RegExp(r'^[a-z0-9]+$').hasMatch(e);
  }

  /// After the EPUB exists locally: fetch cover from Drive, else extract from EPUB.
  Future<void> _downloadOrExtractCoverAfterEpub(Book book) async {
    final coversDir = await _bookService.getCoversDirectory();

    final extensionsToTry = <String>[];
    if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty) {
      final ext = book.coverImagePath!.split('.').last;
      if (_isPlausibleImageExt(ext)) {
        extensionsToTry.add(ext.toLowerCase());
      }
    }
    for (final e in ['png', 'jpg', 'jpeg', 'webp']) {
      if (!extensionsToTry.contains(e)) {
        extensionsToTry.add(e);
      }
    }

    String? savedPath;
    for (final ext in extensionsToTry) {
      final remoteName = '$_coversFolderName/${book.id}.$ext';
      final coverBytes = await _downloadFile(remoteName);
      if (coverBytes == null || coverBytes.isEmpty) continue;

      final targetPath = (book.coverImagePath != null &&
              book.coverImagePath!.toLowerCase().endsWith('.$ext'))
          ? book.coverImagePath!
          : '$coversDir/${book.id}.$ext';

      final out = File(targetPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(coverBytes);
      savedPath = out.path;
      debugPrint('[DriveSync] Downloaded cover for "${book.title}" ($ext)');
      break;
    }

    Book current = book;
    if (savedPath != null) {
      current = Book(
        id: book.id,
        title: book.title,
        author: book.author,
        coverImagePath: savedPath,
        filePath: book.filePath,
        dateAdded: book.dateAdded,
        isValid: book.isValid,
      );
      await _bookService.addOrUpdateBook(current);
    }

    final checkPath = current.coverImagePath;
    if (checkPath != null) {
      final f = File(checkPath);
      if (await f.exists() && await f.length() > 0) {
        return;
      }
    }

    final extracted = await _bookService.extractCoverFromEpubPath(
        book.filePath, book.id);
    if (extracted != null) {
      final withCover = Book(
        id: current.id,
        title: current.title,
        author: current.author,
        coverImagePath: extracted,
        filePath: current.filePath,
        dateAdded: current.dateAdded,
        isValid: current.isValid,
      );
      await _bookService.addOrUpdateBook(withCover);
      debugPrint('[DriveSync] Extracted cover from EPUB for "${book.title}"');
    } else {
      debugPrint(
          '[DriveSync] No cover on Drive and EPUB extraction failed for '
          '"${book.title}"');
    }
  }

  // ---------------------------------------------------------------------------
  // Upload helpers
  // ---------------------------------------------------------------------------

  Future<void> _uploadBooksMetadata() async {
    final books = await _bookService.getAllBooks();
    var deletedBooks = await _getDeletedBooks();

    debugPrint('[DriveSync] Uploading books metadata: '
        '${books.length} book(s), ${deletedBooks.length} tombstone(s)');

    if (books.isEmpty && deletedBooks.isEmpty) {
      debugPrint('[DriveSync] WARNING: both books and tombstones are empty — '
          'skipping upload to avoid overwriting Drive with empty data');
      return;
    }

    // Expire tombstones older than 30 days so they don't grow forever.
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    deletedBooks.removeWhere((_, v) => v.isBefore(cutoff));
    await _saveDeletedBooks(deletedBooks);

    final syncData = SyncBooksData(
      books: books,
      deletedBooks: deletedBooks,
      lastModified: DateTime.now(),
    );
    await _uploadFile(
      _booksFileName,
      utf8.encode(jsonEncode(syncData.toJson())),
      'application/json',
    );
  }

  Future<void> _uploadProgress() async {
    final books = await _bookService.getAllBooks();
    final progressMap = <String, ReadingProgress>{};
    for (final book in books) {
      final p = await _bookService.getReadingProgress(book.id);
      if (p != null) progressMap[book.id] = p;
    }
    final syncData =
        SyncProgressData(progress: progressMap, lastModified: DateTime.now());
    await _uploadFile(
      _progressFileName,
      utf8.encode(jsonEncode(syncData.toJson())),
      'application/json',
    );
  }

  Future<void> _uploadTranslations() async {
    final books = await _bookService.getAllBooks();
    final all = <SavedTranslation>[];
    for (final book in books) {
      all.addAll(await _translationService.getTranslations(book.id));
    }
    final syncData =
        SyncTranslationsData(translations: all, lastModified: DateTime.now());
    await _uploadFile(
      _translationsFileName,
      utf8.encode(jsonEncode(syncData.toJson())),
      'application/json',
    );
  }

  Future<void> _uploadApiKeys() async {
    if (!await DriveSyncSecretsService.canEncryptApiKeysForUpload()) {
      debugPrint(
        '[DriveSync] API keys upload skipped — cloud encryption off or no '
        'passphrase (keys are not stored on Drive in plaintext)',
      );
      return;
    }
    final passphrase = await DriveSyncSecretsService.getPassphrase();
    if (passphrase == null || passphrase.isEmpty) {
      debugPrint('[DriveSync] API keys upload skipped — passphrase missing');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final config = SummaryConfigService(prefs);
    final syncData = SyncApiKeysData(
      openaiApiKey: config.getRawOpenAIApiKey(),
      mistralApiKey: config.getRawMistralApiKey(),
      provider: config.getProvider(),
      lastModified: DateTime.now(),
    );
    final plain = utf8.encode(jsonEncode(syncData.toJson()));
    final envelope = await DriveApiKeysCipher.encrypt(
      plaintextUtf8: plain,
      passphrase: passphrase,
    );
    await _uploadFile(
      _apiKeysFileName,
      utf8.encode(jsonEncode(envelope)),
      'application/json',
    );
    debugPrint('[DriveSync] Encrypted API keys uploaded');
  }

  // ---------------------------------------------------------------------------
  // Download / merge helpers
  // ---------------------------------------------------------------------------

  /// Merges remote book metadata with local state.
  ///
  /// The algorithm is a single-pass "last-write-wins" over all known book IDs:
  ///
  ///   • For each book ID seen in any source (local books, remote books, local
  ///     tombstones, remote tombstones), determine the most-recent *alive*
  ///     timestamp (= newest `dateAdded` across both devices) and the
  ///     most-recent *deletion* timestamp.
  ///
  ///   • If alive > deleted (or no deletion): the book should exist.
  ///   • If deleted >= alive (or no alive event): the book should be gone.
  ///
  ///   Then enforce that state locally.
  Future<void> _downloadAndMergeBooks() async {
    try {
      final jsonBytes = await _downloadFile(_booksFileName);
      if (jsonBytes == null) {
        debugPrint('[DriveSync] No books file on Drive — skipping book merge');
        return;
      }

      final remoteData = SyncBooksData.fromJson(
        jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>,
        booksDirectory: await _bookService.getBooksDirectory(),
        coversDirectory: await _bookService.getCoversDirectory(),
      );

      debugPrint('[DriveSync] Remote has ${remoteData.books.length} book(s), '
          '${remoteData.deletedBooks.length} tombstone(s)');

      final localBooks = await _bookService.getAllBooks();
      final localDeletedBooks = await _getDeletedBooks();

      debugPrint('[DriveSync] Local has ${localBooks.length} book(s), '
          '${localDeletedBooks.length} tombstone(s)');

      final localBookMap = {for (final b in localBooks) b.id: b};
      final remoteBookMap = {for (final b in remoteData.books) b.id: b};

      final allIds = {
        ...localBookMap.keys,
        ...remoteBookMap.keys,
        ...localDeletedBooks.keys,
        ...remoteData.deletedBooks.keys,
      };

      for (final bookId in allIds) {
        try {
          final localBook = localBookMap[bookId];
          final remoteBook = remoteBookMap[bookId];
          final localDeletion = localDeletedBooks[bookId];
          final remoteDeletion = remoteData.deletedBooks[bookId];

          final (:newestBook, :newestDeletion) =
              mergeBookAndDeletionTimestamps(
            localBook: localBook,
            remoteBook: remoteBook,
            localDeletion: localDeletion,
            remoteDeletion: remoteDeletion,
          );

          final shouldExist =
              bookShouldExistAfterMerge(newestBook, newestDeletion);

          if (shouldExist) {
            final resolvedBook = newestBook!;
            if (localBook == null) {
              await _bookService.addOrUpdateBook(resolvedBook);
              debugPrint(
                  '[DriveSync] Added book "${resolvedBook.title}" from Drive');
            } else if (remoteBook != null &&
                remoteBook.dateAdded.isAfter(localBook.dateAdded)) {
              await _bookService.addOrUpdateBook(remoteBook);
              debugPrint(
                  '[DriveSync] Updated book "${remoteBook.title}" from Drive');
            }
            if (localDeletion != null) await _untrackBookDeletion(bookId);
          } else {
            if (localBook != null) {
              await _bookService.deleteBook(localBook);
              // Queue Drive blob cleanup so EPUB/cover are removed from Drive
              // on the next upload phase (mirrors what onBookDeleted does for
              // user-initiated deletes).
              await _enqueueDriveBlobDelete(bookId);
              debugPrint(
                  '[DriveSync] Deleted book "${localBook.title}" per remote state');
            }
            if (localDeletion == null) await _trackBookDeletion(bookId);
          }
        } catch (e) {
          debugPrint('[DriveSync] Error merging book $bookId: $e');
          _downloadHadErrors = true;
        }
      }
    } catch (e) {
      debugPrint('[DriveSync] Error downloading books: $e');
      _downloadHadErrors = true;
    }
  }

  Future<void> _downloadAndMergeProgress() async {
    try {
      final jsonBytes = await _downloadFile(_progressFileName);
      if (jsonBytes == null) return;

      final remoteData = SyncProgressData.fromJson(
        jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>,
      );

      // Only apply progress for books that exist locally after the book merge
      // to avoid creating orphaned progress entries for deleted books.
      final localBooks = await _bookService.getAllBooks();
      final localBookIds = {for (final b in localBooks) b.id};

      for (final entry in remoteData.progress.entries) {
        if (!localBookIds.contains(entry.key)) continue;
        final local = await _bookService.getReadingProgress(entry.key);
        if (local == null || entry.value.lastRead.isAfter(local.lastRead)) {
          await _bookService.saveReadingProgress(entry.value);
        }
      }
    } catch (e) {
      debugPrint('[DriveSync] Error downloading progress: $e');
      _downloadHadErrors = true;
    }
  }

  Future<void> _downloadAndMergeTranslations() async {
    try {
      final jsonBytes = await _downloadFile(_translationsFileName);
      if (jsonBytes == null) return;

      final remoteData = SyncTranslationsData.fromJson(
        jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>,
      );

      final books = await _bookService.getAllBooks();
      final localBookIds = {for (final b in books) b.id};
      final localTranslations = <SavedTranslation>[];
      for (final book in books) {
        localTranslations.addAll(
            await _translationService.getTranslations(book.id));
      }
      final localMap = {
        for (final t in localTranslations)
          if (t.id != null) t.id!: t,
      };

      for (final remote in remoteData.translations) {
        if (!localBookIds.contains(remote.bookId)) {
          continue;
        }
        final local = remote.id != null ? localMap[remote.id] : null;
        if (local == null || remote.createdAt.isAfter(local.createdAt)) {
          await _translationService.saveTranslation(remote);
        }
      }
    } catch (e) {
      debugPrint('[DriveSync] Error downloading translations: $e');
      _downloadHadErrors = true;
    }
  }

  Future<void> _downloadAndMergeApiKeys() async {
    try {
      apiKeysSyncIssue.value = null;
      final jsonBytes = await _downloadFile(_apiKeysFileName);
      if (jsonBytes == null) return;

      final map =
          jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

      late final SyncApiKeysData remote;
      if (DriveApiKeysCipher.isEncryptedEnvelope(map)) {
        final passphrase = await DriveSyncSecretsService.getPassphrase();
        if (passphrase == null || passphrase.isEmpty) {
          apiKeysSyncIssue.value = DriveApiKeysSyncIssue.missingPassphrase;
          debugPrint(
            '[DriveSync] Encrypted API keys on Drive — passphrase missing',
          );
          return;
        }
        try {
          final plain = await DriveApiKeysCipher.decrypt(
            envelope: map,
            passphrase: passphrase,
          );
          remote = SyncApiKeysData.fromJson(
            jsonDecode(utf8.decode(plain)) as Map<String, dynamic>,
          );
        } on DriveApiKeysDecryptException catch (e) {
          apiKeysSyncIssue.value = DriveApiKeysSyncIssue.decryptFailed;
          debugPrint('[DriveSync] API key decrypt failed: $e');
          return;
        }
      } else {
        try {
          remote = SyncApiKeysData.fromJson(map);
        } catch (e) {
          apiKeysSyncIssue.value = DriveApiKeysSyncIssue.unreadableRemote;
          debugPrint('[DriveSync] API keys JSON parse error: $e');
          return;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final config = SummaryConfigService(prefs);

      // Merge policy: only populate empty local slots from Drive.
      // We never overwrite a key the user has already set on this device to
      // avoid accidentally clobbering intentional local configuration.
      bool updated = false;

      if (remote.openaiApiKey?.isNotEmpty == true) {
        final local = config.getRawOpenAIApiKey();
        if (local == null || local.isEmpty) {
          await config.setOpenAIApiKey(remote.openaiApiKey!);
          updated = true;
          debugPrint('[DriveSync] Populated OpenAI API key from Drive');
        }
      }
      if (remote.mistralApiKey?.isNotEmpty == true) {
        final local = config.getRawMistralApiKey();
        if (local == null || local.isEmpty) {
          await config.setMistralApiKey(remote.mistralApiKey!);
          updated = true;
          debugPrint('[DriveSync] Populated Mistral API key from Drive');
        }
      }
      // Provider: only apply if the user hasn't explicitly chosen one locally.
      // getProvider() always returns a default, so we inspect SharedPreferences
      // directly.  'summary_provider' is the key used by SummaryConfigService.
      final prefs2 = await SharedPreferences.getInstance();
      if (remote.provider != null &&
          !prefs2.containsKey('summary_provider')) {
        await config.setProvider(remote.provider!);
        updated = true;
        debugPrint('[DriveSync] Populated provider from Drive: ${remote.provider}');
      }

      if (!updated) debugPrint('[DriveSync] API keys already in sync');
    } catch (e) {
      debugPrint('[DriveSync] Error downloading API keys: $e');
      _downloadHadErrors = true;
    }
  }

  // ---------------------------------------------------------------------------
  // Uploaded-books inventory
  // ---------------------------------------------------------------------------

  /// Lists all EPUB files in the appDataFolder and populates
  /// [_uploadedBookIds] so the UI can show "Already uploaded".
  Future<void> _refreshUploadedBookIds() async {
    if (!isAuthenticated) return;
    try {
      final response = await _driveApi!.files.list(
        q: "'appDataFolder' in parents",
        spaces: 'appDataFolder',
        $fields: 'files(name)',
      );
      _uploadedBookIds.clear();
      for (final file in response.files ?? <drive.File>[]) {
        final name = file.name;
        if (name != null &&
            name.startsWith('$_booksFolderName/') &&
            name.endsWith('.epub')) {
          final id = name
              .substring('$_booksFolderName/'.length,
                  name.length - '.epub'.length);
          if (id.isNotEmpty) _uploadedBookIds.add(id);
        }
      }
      debugPrint(
          '[DriveSync] Found ${_uploadedBookIds.length} EPUB(s) on Drive');
    } catch (e) {
      debugPrint('[DriveSync] Error listing uploaded books: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Drive API primitives
  // ---------------------------------------------------------------------------

  /// Uploads [fileBytes] to the appDataFolder under [fileName].
  /// Creates the file if it doesn't exist; updates it if it does.
  Future<void> _uploadFile(
    String fileName,
    List<int> fileBytes,
    String mimeType,
  ) async {
    if (!isAuthenticated) throw Exception('Not authenticated');
    try {
      final existing = await _findFile(fileName);
      final media = drive.Media(
        Stream.value(fileBytes),
        fileBytes.length,
        contentType: mimeType,
      );

      if (existing != null) {
        await _driveApi!.files.update(
          drive.File()..name = fileName,
          existing.id!,
          uploadMedia: media,
        );
        debugPrint('[DriveSync] Updated $fileName');
      } else {
        await _driveApi!.files.create(
          drive.File()
            ..name = fileName
            ..parents = ['appDataFolder'],
          uploadMedia: media,
        );
        debugPrint('[DriveSync] Created $fileName');
      }
    } catch (e) {
      debugPrint('[DriveSync] Error uploading $fileName: $e');
      rethrow;
    }
  }

  /// Downloads [fileName] from the appDataFolder.
  ///
  /// Returns `null` when the file does not exist on Drive (not an error).
  /// Throws on API/network failures so callers can correctly set
  /// [_downloadHadErrors] rather than silently treating errors as "not found".
  Future<List<int>?> _downloadFile(String fileName) async {
    if (!isAuthenticated) throw Exception('Not authenticated');
    final file = await _findFile(fileName);
    if (file == null) return null; // file not on Drive — not an error

    // File was found; fetch its bytes. Let any API/network error propagate.
    final response = await _driveApi!.files.get(
      file.id!,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
    }
    debugPrint('[DriveSync] Downloaded $fileName (${bytes.length} bytes)');
    return bytes;
  }

  /// Finds a file by [fileName] in the appDataFolder.
  ///
  /// Returns `null` when the file is not found. Throws on API/network errors.
  Future<drive.File?> _findFile(String fileName) async {
    if (!isAuthenticated) throw Exception('Not authenticated');
    final response = await _driveApi!.files.list(
      q: "name='$fileName' and 'appDataFolder' in parents",
      spaces: 'appDataFolder',
    );
    return response.files?.firstOrNull;
  }

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

// ---------------------------------------------------------------------------
// Authenticated HTTP client
// ---------------------------------------------------------------------------

/// HTTP client that injects fresh Google OAuth headers on every request.
///
/// By calling [GoogleSignInAccount.authHeaders] per-request rather than
/// caching the headers at sign-in time, we let the Google Sign-In SDK handle
/// token refresh transparently.  OAuth access tokens expire after ~1 hour;
/// the SDK refreshes them automatically when [authHeaders] is awaited.
class _AuthenticatedHttpClient extends http.BaseClient {
  final GoogleSignIn _googleSignIn;
  final http.Client _inner = http.Client();

  _AuthenticatedHttpClient(this._googleSignIn);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final user = _googleSignIn.currentUser;
    if (user != null) {
      final headers = await user.authHeaders;
      headers.forEach((k, v) => request.headers[k] = v);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
