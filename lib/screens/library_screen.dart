import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import '../services/app_state_service.dart';
import '../services/sharing_service.dart';
import '../services/rag_indexing_service.dart';
import '../services/rag_database_service.dart';
import '../services/google_drive_sync_service.dart';
import '../utils/import_extensions.dart';
import '../widgets/book_cover_image.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'rag_question_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final BookService _bookService = BookService();
  final AppStateService _appStateService = AppStateService();
  final GoogleDriveSyncService _driveSyncService = GoogleDriveSyncService();
  List<Book> _books = [];
  Map<String, ReadingProgress> _bookProgress = {}; // Map bookId to progress
  bool _isLoading = true;
  bool _isImporting = false;
  String? _errorMessage;
  bool _isListView = false;
  bool _syncEnabled = false;
  StreamSubscription? _sharingSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLibraryViewPreference());
    // Delay loading books to ensure Flutter platform channels are ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _loadBooks();
      });
    });
    unawaited(_appStateService.clearLastOpenedBook());

    // Listen to books imported via "Open with"
    _sharingSubscription = SharingService().onBookImported.listen((book) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.bookImportedSuccessfully),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
        _loadBooks();
      }
    });
  }

  @override
  void dispose() {
    _sharingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadLibraryViewPreference() async {
    final isList = await _appStateService.getLibraryViewIsList();
    if (!mounted) {
      return;
    }
    setState(() {
      _isListView = isList;
    });
  }

  Future<void> _loadBooks() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    
    try {
      final results = await Future.wait([
        _bookService.getAllBooks(),
        _driveSyncService.isSyncEnabled(),
      ]);
      final books = results[0] as List<Book>;
      final syncEnabled = results[1] as bool;

      // Validate book files and load progress in parallel
      final validationFutures = books.map((book) => _validateBookFile(book));
      final validatedBooks = await Future.wait(validationFutures);
      
      // Load progress for all books in parallel
      final progressFutures = validatedBooks.map((book) => _bookService.getReadingProgress(book.id));
      final progressList = await Future.wait(progressFutures);
      
      final progressMap = <String, ReadingProgress>{};
      for (int i = 0; i < validatedBooks.length; i++) {
        final progress = progressList[i];
        if (progress != null) {
          progressMap[validatedBooks[i].id] = progress;
        }
      }

      setState(() {
        _books = validatedBooks;
        _bookProgress = progressMap;
        _syncEnabled = syncEnabled;
        _isLoading = false;
      });
      
      // Trigger RAG indexing for unindexed books (in background)
      _triggerRagIndexingForUnindexedBooks(validatedBooks).catchError((e) {
        debugPrint('Failed to trigger RAG indexing: $e');
      });
      
      // Don't generate summaries on library load - only when user leaves a book or app goes to background
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading books: $e';
        _isLoading = false;
      });
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorLoadingBooks(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Trigger RAG indexing for books that need indexing
  Future<void> _triggerRagIndexingForUnindexedBooks(List<Book> books) async {
    try {
      final ragDbService = RagDatabaseService();
      final ragIndexingService = RagIndexingService();

      for (final book in books) {
        final status = await ragDbService.getIndexStatus(book.id);
        
        // Skip if already completed
        if (status != null && status.isComplete) {
          continue;
        }

        // Check if indexing is actually running (not just marked as indexing in DB)
        // If status says indexing but no isolate is running, restart indexing
        final isActuallyIndexing = ragIndexingService.isIndexing(book.id);
        
        if (status != null && status.isIndexing && isActuallyIndexing) {
          // Already indexing with active isolate, skip
          continue;
        }

        // Start indexing (non-blocking) - will resume from where it left off if interrupted
        ragIndexingService.startIndexing(book.id).listen(
          (progress) {
            debugPrint('[RAG] Indexing progress for ${book.id}: ${progress.indexedChunks}/${progress.totalChunks}');
          },
          onError: (error) {
            debugPrint('[RAG] Indexing error for ${book.id}: $error');
          },
        );
      }
    } catch (e) {
      debugPrint('Failed to trigger RAG indexing: $e');
      // Don't throw - indexing is non-critical
    }
  }

  Future<Book> _validateBookFile(Book book) async {
    try {
      final file = File(book.filePath);
      final exists = await file.exists();
      
      if (!exists && book.isValid) {
        // File doesn't exist but book is marked as valid - update it
        final invalidBook = Book(
          id: book.id,
          title: book.title,
          author: book.author,
          coverImagePath: book.coverImagePath,
          filePath: book.filePath,
          dateAdded: book.dateAdded,
          isValid: false,
        );
        // Save the updated status
        await _bookService.updateBook(invalidBook);
        return invalidBook;
      } else if (exists && !book.isValid) {
        // File exists but book is marked as invalid - update it
        final validBook = Book(
          id: book.id,
          title: book.title,
          author: book.author,
          coverImagePath: book.coverImagePath,
          filePath: book.filePath,
          dateAdded: book.dateAdded,
          isValid: true,
        );
        await _bookService.updateBook(validBook);
        return validBook;
      }
      
      return book;
    } catch (e) {
      debugPrint('Error validating book ${book.title}: $e');
      return book;
    }
  }

  /// Imports a book file based on its extension (txt, pdf, or epub).
  Future<Book?> _importBookByExtension(File file, String extension) async {
    switch (extension) {
      case 'txt':
        return _bookService.importTxt(file);
      case 'pdf':
        return _bookService.importPdf(file);
      case 'epub':
      default:
        return _bookService.importEpub(file);
    }
  }

  Future<void> _importEpub() async {
    if (_isImporting) return;
    
    setState(() {
      _isImporting = true;
    });

    try {
      debugPrint('Starting file picker...');
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowedBookImportExtensions,
        withData: false,
        withReadStream: false,
      );

      debugPrint('File picker result: ${result?.files.length ?? 0} files');
      
      if (result != null && result.files.isNotEmpty) {
        final pickedFile = result.files.single;
        debugPrint('Picked file: ${pickedFile.name}, path: ${pickedFile.path}');
        
        if (pickedFile.path == null) {
          throw Exception('File path is null. This may be a macOS permissions issue.');
        }
        final filePath = pickedFile.path!;
        final file = File(filePath);
        
        debugPrint('Checking if file exists: $filePath');
        if (!await file.exists()) {
          throw Exception('Selected file no longer exists: $filePath');
        }
        
        debugPrint('File exists, starting import...');
        
        // Show progress indicator
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(l10n.importingEpub),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        
        final extension = extensionFromPath(filePath);
        debugPrint('Importing file with extension: $extension');

        final Book? importedBook = await _importBookByExtension(file, extension);
        
        // If book was re-imported (was previously deleted), remove from deletion tracking
        if (importedBook != null) {
          final syncEnabled = await _driveSyncService.isSyncEnabled();
          if (syncEnabled) {
            // Check if this book was previously deleted and remove from tracking
            // The upload logic will handle this, but we can also do it here for immediate effect
            await _driveSyncService.onBookReAdded(importedBook.id);
          }
        }

        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          Navigator.pop(context); // Close progress dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.bookImportedSuccessfully),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
          _loadBooks();
        }
      } else {
        debugPrint('File picker was cancelled or returned null');
      }
    } catch (e, stackTrace) {
      debugPrint('Error importing EPUB: $e');
      debugPrint('Stack trace: $stackTrace');
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        // Try to close progress dialog if open
        try {
          Navigator.pop(context);
        } catch (_) {
          // Dialog might not be open
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.errorImportingBook(e.toString())}\n\nVérifiez les permissions macOS dans Préférences Système > Sécurité.'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      setState(() {
        _isImporting = false;
      });
    }
  }

  void _openBook(Book book) {
    if (!book.isValid) {
      _handleInvalidBookTap(book);
      return;
    }

    unawaited(_appStateService.setLastOpenedBook(book.id));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderScreen(book: book),
      ),
    ).then((_) async {
      await _loadBooks();
      await _appStateService.clearLastOpenedBook();
    });
  }

  /// Called when the user taps a book whose local file is missing.
  ///
  /// If Google Drive sync is enabled, offers to download the EPUB from Drive.
  /// Otherwise shows the existing "file not found" snackbar.
  Future<void> _handleInvalidBookTap(Book book) async {
    final syncEnabled = await _driveSyncService.isSyncEnabled();
    if (!mounted) return;

    if (!syncEnabled) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.bookFileNotFound),
          backgroundColor: Colors.orange,
          action: SnackBarAction(
            label: l10n.delete,
            textColor: Colors.white,
            onPressed: () => _deleteBookFromLibrary(book, l10n),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    _showDriveDownloadDialog(book);
  }

  /// Shows a confirmation dialog offering to download [book] from Google Drive.
  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openSettingsToGoogleSync() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const SettingsScreen(scrollToSync: true),
      ),
    ).then((_) => _loadBooks());
  }

  Widget _buildLibraryOnboarding(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyLarge?.copyWith(height: 1.45);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.cloud_outlined, size: 44, color: scheme.primary),
                const SizedBox(height: 12),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    Text(l10n.libraryOnboardingSyncPrefix, style: bodyStyle),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _openSettingsToGoogleSync,
                      child: Text(
                        l10n.libraryOnboardingSyncHere,
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Icon(Icons.auto_awesome, size: 44, color: scheme.tertiary),
                const SizedBox(height: 12),
                Text(
                  l10n.libraryOnboardingAiPrefix,
                  style: bodyStyle,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 4,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _openExternalUrl(
                          'https://console.mistral.ai/api-keys'),
                      child: Text(
                        l10n.libraryOnboardingGetMistralKey,
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    Text(
                      l10n.libraryOnboardingAiOrBetweenProviders,
                      style: bodyStyle,
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _openExternalUrl(
                          'https://platform.openai.com/api-keys'),
                      child: Text(
                        l10n.libraryOnboardingGetOpenAIKey,
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                Text(
                  l10n.libraryOnboardingImportBody,
                  style: bodyStyle,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showDriveDownloadDialog(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(book.title),
        content: const Text(
          'The file for this book is not on this device.\n\n'
          'Download it from Google Drive?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final ok = await _driveSyncService.downloadBookFromDrive(book);
      if (!mounted) return;
      if (ok) {
        final coverPath = book.coverImagePath;
        if (coverPath != null && coverPath.isNotEmpty) {
          await FileImage(File(coverPath)).evict();
        }
        PaintingBinding.instance.imageCache.clear();
        await _loadBooks();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This book is not available on Google Drive.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildBooksGrid(AppLocalizations l10n) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.7,
      ),
      itemCount: _books.length,
      itemBuilder: (context, index) {
        final book = _books[index];
        return _buildDismissibleBookItem(
          book: book,
          index: index,
          l10n: l10n,
          child: _buildGridBookCard(book, index, l10n),
        );
      },
    );
  }

  Widget _buildBooksList(AppLocalizations l10n) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      itemBuilder: (context, index) {
        final book = _books[index];
        return _buildDismissibleBookItem(
          book: book,
          index: index,
          l10n: l10n,
          child: _buildListBookCard(book, index, l10n),
        );
      },
      separatorBuilder: (context, index) => const SizedBox(height: 16),
      itemCount: _books.length,
    );
  }

  Widget _buildDismissibleBookItem({
    required Book book,
    required int index,
    required AppLocalizations l10n,
    required Widget child,
  }) {
    return Dismissible(
      key: Key('${book.id}_${_isListView ? 'list' : 'grid'}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmBookDismiss(book, l10n),
      onDismissed: (_) {
        unawaited(_deleteBookFromLibrary(book, l10n));
      },
      child: child,
    );
  }

  Future<bool> _confirmBookDismiss(Book book, AppLocalizations l10n) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteBook),
        content: Text(l10n.confirmDeleteBook(book.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showBookDeletedSnackBar(
    AppLocalizations l10n,
    String title, {
    required bool syncEnabled,
    required bool driveBlobsHandled,
  }) {
    final lines = <String>[l10n.bookDeleted(title)];
    if (syncEnabled) {
      lines.add(
        driveBlobsHandled
            ? l10n.driveBookFilesRemovedFromCloud
            : l10n.driveBookFilesRemovalQueued,
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(lines.join('\n')),
        duration: Duration(seconds: syncEnabled ? 4 : 2),
      ),
    );
  }

  Future<void> _deleteBookAndRefreshLibrary(
      Book book, AppLocalizations l10n) async {
    await _bookService.deleteBook(book);
    var driveBlobsHandled = false;
    final syncEnabled = await _driveSyncService.isSyncEnabled();
    if (syncEnabled) {
      driveBlobsHandled = await _driveSyncService.onBookDeleted(book.id);
    }
    if (!mounted) return;
    _showBookDeletedSnackBar(
      l10n,
      book.title,
      syncEnabled: syncEnabled,
      driveBlobsHandled: driveBlobsHandled,
    );
    await _loadBooks();
  }

  Future<void> _deleteBookFromLibrary(Book book, AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _deleteBookAndRefreshLibrary(book, l10n);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.errorDeletingBook(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildGridBookCard(Book book, int index, AppLocalizations l10n) {
    final progressInfo = _getProgressInfo(book);
    return Opacity(
      opacity: book.isValid ? 1.0 : 0.5,
      child: Card(
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          onTap: () => _openBook(book),
          onLongPress: () => _showDeleteDialog(book, index),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              BookCoverImage(book: book),
              if (!book.isValid)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Icon(
                        Icons.error_outline,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              if (_isBookCompleted(book))
                Positioned.fill(
                  child: _buildReadWatermark(),
                ),
              Positioned(
                top: 8,
                right: 8,
                child: _buildBookMenu(book, l10n, onDarkBackground: true),
              ),
              _buildGridInfoOverlay(book, progressInfo),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridInfoOverlay(Book book, _ProgressInfo? progressInfo) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.0),
              Colors.black.withOpacity(0.55),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              book.title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              book.author,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (progressInfo != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progressInfo.value,
                  minHeight: 6,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${progressInfo.label}%',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildListBookCard(Book book, int index, AppLocalizations l10n) {
    final progressInfo = _getProgressInfo(book);
    final theme = Theme.of(context);
    return Opacity(
      opacity: book.isValid ? 1.0 : 0.5,
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openBook(book),
          onLongPress: () => _showDeleteDialog(book, index),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  height: 130,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        BookCoverImage(book: book),
                        if (!book.isValid)
                          Container(
                            color: Colors.black54,
                            child: const Center(
                              child: Icon(
                                Icons.error_outline,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          ),
                        if (_isBookCompleted(book))
                          Positioned.fill(child: _buildReadWatermark()),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      book.author,
                      style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (progressInfo != null) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progressInfo.value,
                          minHeight: 6,
                          backgroundColor: theme.colorScheme.surfaceVariant,
                          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${progressInfo.label}%',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildBookMenu(book, l10n),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildBookMenu(Book book, AppLocalizations l10n, {bool onDarkBackground = false}) {
    final backgroundColor = onDarkBackground ? Colors.black.withOpacity(0.45) : Colors.white.withOpacity(0.9);
    final iconColor = onDarkBackground ? Colors.white : Colors.black87;
    return PopupMenuButton<String>(
      icon: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.more_vert,
          size: 18,
          color: iconColor,
        ),
      ),
      onSelected: (value) {
        if (value == 'delete') {
          _showDeleteConfirmationDialog(book);
        } else if (value == 'upload_to_drive') {
          _uploadBookToDrive(book);
        }
      },
      itemBuilder: (context) => [
        if (_syncEnabled && book.isValid)
          _driveSyncService.isBookUploadedToDrive(book.id)
              ? const PopupMenuItem<String>(
                  enabled: false,
                  value: 'upload_to_drive',
                  child: Row(
                    children: [
                      Icon(Icons.cloud_done, size: 20, color: Colors.grey),
                      SizedBox(width: 8),
                      Text('Already uploaded',
                          style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : const PopupMenuItem<String>(
                  value: 'upload_to_drive',
                  child: Row(
                    children: [
                      Icon(Icons.cloud_upload_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('Upload to Drive'),
                    ],
                  ),
                ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              const Icon(Icons.delete, size: 20),
              const SizedBox(width: 8),
              Text(l10n.delete),
            ],
          ),
        ),
      ],
    );
  }

  /// Upload [book]'s EPUB to Google Drive.
  Future<void> _uploadBookToDrive(Book book) async {
    try {
      await _driveSyncService.uploadBookToDrive(book);
      if (mounted) {
        setState(() {}); // refresh menu to show "Already uploaded"
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"${book.title}" uploaded to Google Drive'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showDeleteDialog(Book book, int index) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteBook),
        content: Text(l10n.confirmDeleteBook(book.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true) {
        try {
          if (!mounted) return;
          final l10n = AppLocalizations.of(context)!;
          await _deleteBookAndRefreshLibrary(book, l10n);
        } catch (e) {
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.errorDeletingBook(e.toString())),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    });
  }

  void _showDeleteConfirmationDialog(Book book) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.deleteBookConfirm),
        actions: [
          // Cancel button on the left
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          // Confirm button on the right
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true) {
        try {
          if (!mounted) return;
          final l10n = AppLocalizations.of(context)!;
          await _deleteBookAndRefreshLibrary(book, l10n);
        } catch (e) {
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.errorDeletingBook(e.toString())),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.library),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              ).then((_) => _loadBooks());
            },
            tooltip: l10n.settings,
          ),
          if (_books.isNotEmpty)
            IconButton(
              icon: Icon(_isListView ? Icons.grid_view : Icons.view_list),
              onPressed: () {
                setState(() {
                  _isListView = !_isListView;
                });
                unawaited(
                  _appStateService.setLibraryViewIsList(_isListView),
                );
              },
              tooltip: _isListView ? l10n.libraryShowGrid : l10n.libraryShowList,
            ),
          if (_books.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadBooks,
              tooltip: l10n.refresh,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        style: TextStyle(color: Colors.red[600]),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadBooks,
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                )
              : _books.isEmpty
                  ? _buildLibraryOnboarding(l10n)
                  : RefreshIndicator(
                      onRefresh: _loadBooks,
                      child: _isListView
                          ? _buildBooksList(l10n)
                          : _buildBooksGrid(l10n),
                    ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_books.isNotEmpty)
            FloatingActionButton(
              heroTag: 'ask_library_fab',
              onPressed: _openLibraryQuestionScreen,
              tooltip: l10n.libraryAskQuestion,
              child: const Icon(Icons.question_answer_outlined),
            ),
          if (_books.isNotEmpty) const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'import_fab',
            onPressed: _isImporting ? null : _importEpub,
            tooltip: l10n.importEpub,
            child: _isImporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Future<void> _openLibraryQuestionScreen() async {
    // Build read-positions map from already-loaded _bookProgress
    final positions = <String, int?>{};
    for (final book in _books) {
      positions[book.id] = _bookProgress[book.id]?.currentCharacterIndex;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RagQuestionScreen(
          books: _books,
          currentBookId: null,
          bookReadPositions: positions,
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(Book book) {
    final info = _getProgressInfo(book);
    if (info == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: info.value,
                    minHeight: 6,
                    backgroundColor: Colors.grey[200],
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${info.label}%',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[700],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _ProgressInfo? _getProgressInfo(Book book) {
    final progress = _bookProgress[book.id];
    if (progress == null) {
      return null;
    }

    double progressValue = progress.progress ?? 0;
    progressValue = progressValue.clamp(0.0, 1.0);

    if (progressValue <= 0.0) {
      return null;
    }

    final progressPercentage = (progressValue * 100).toStringAsFixed(0);
    return _ProgressInfo(value: progressValue, label: progressPercentage);
  }

  bool _isBookCompleted(Book book) {
    final progress = _bookProgress[book.id];
    if (progress == null) return false;

    final progressValue = (progress.progress ?? 0).clamp(0.0, 1.0);
    return progressValue >= 0.99;
  }

  Widget _buildReadWatermark() {
    return Transform.rotate(
      angle: -0.5, // Rotate -28.6 degrees (roughly -0.5 radians)
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        child: Center(
          child: Text(
            'READ',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white.withValues(alpha: 0.9),
              letterSpacing: 4,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressInfo {
  const _ProgressInfo({required this.value, required this.label});

  final double value;
  final String label;
}
