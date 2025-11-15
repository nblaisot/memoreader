import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import '../services/background_summary_service.dart';
import '../services/app_state_service.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final BookService _bookService = BookService();
  final AppStateService _appStateService = AppStateService();
  List<Book> _books = [];
  Map<String, ReadingProgress> _bookProgress = {}; // Map bookId to progress
  Map<String, int> _bookTotalChapters = {}; // Cache total chapters per book
  bool _isLoading = true;
  bool _isImporting = false;
  String? _errorMessage;
  bool _isListView = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLibraryViewPreference());
    _loadBooks();
    unawaited(_appStateService.clearLastOpenedBook());
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
      final books = await _bookService.getAllBooks();
      
      // Load progress for all books and total chapters
      final progressMap = <String, ReadingProgress>{};
      final chaptersMap = <String, int>{};
      
      for (final book in books) {
        final progress = await _bookService.getReadingProgress(book.id);
        if (progress != null) {
          progressMap[book.id] = progress;
          
          // Load book to get total chapters (cache it)
          try {
            final epubBook = await _bookService.loadEpubBook(book.filePath);
            final totalChapters = epubBook.Chapters?.length ?? 0;
            if (totalChapters > 0) {
              chaptersMap[book.id] = totalChapters;
            }
          } catch (e) {
            // If loading fails, use estimate
            debugPrint('Failed to load chapters for ${book.id}: $e');
          }
        }
      }
      
      setState(() {
        _books = books;
        _bookProgress = progressMap;
        _bookTotalChapters = chaptersMap;
        _isLoading = false;
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

  Future<void> _importEpub() async {
    if (_isImporting) return;
    
    setState(() {
      _isImporting = true;
    });

    try {
      debugPrint('Starting file picker...');
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
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
        
        // Import the book
        await _bookService.importEpub(file);

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
    unawaited(_appStateService.setLastOpenedBook(book.id));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderScreen(book: book),
      ),
    ).then((_) async {
      // User returned from reading a book
      // Reload books to refresh progress first
      await _loadBooks();

      await _appStateService.clearLastOpenedBook();

      // Generate summaries for the book that was just read (if it has progress)
      // Use fresh progress after reload
      final progress = _bookProgress[book.id];
      if (progress != null && progress.currentChapterIndex != null && progress.currentChapterIndex! > 0) {
        final appLocale = Localizations.localeOf(context);
        final languageCode = appLocale.languageCode;
        // Generate in background without blocking - fire and forget
        // generateSummariesIfNeeded is now void and completely non-blocking
        BackgroundSummaryService().generateSummariesIfNeeded(
          book,
          progress,
          languageCode,
        );
      }
    });
  }

  /// Trigger background summary generation for all books that need it
  void _triggerBackgroundSummaryGeneration(
    List<Book> books,
    Map<String, ReadingProgress> progressMap,
  ) {
    final appLocale = Localizations.localeOf(context);
    final languageCode = appLocale.languageCode;

    for (final book in books) {
      final progress = progressMap[book.id];
      if (progress != null && progress.currentChapterIndex != null && progress.currentChapterIndex! > 0) {
        // Generate in background without waiting (void method, completely non-blocking)
        // generateSummariesIfNeeded handles errors internally
        BackgroundSummaryService().generateSummariesIfNeeded(
          book,
          progress,
          languageCode,
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

  Future<void> _deleteBookFromLibrary(Book book, AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _bookService.deleteBook(book);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.bookDeleted(book.title)),
          duration: const Duration(seconds: 2),
        ),
      );
      await _loadBooks();
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
    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _openBook(book),
        onLongPress: () => _showDeleteDialog(book, index),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildCoverImage(book),
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
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openBook(book),
        onLongPress: () => _showDeleteDialog(book, index),
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
                      _buildCoverImage(book),
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
    );
  }

  Widget _buildCoverImage(Book book) {
    if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty) {
      return Image.file(
        File(book.coverImagePath!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          debugPrint('Error loading cover image: $error');
          return _buildDefaultCover(book);
        },
      );
    }
    return _buildDefaultCover(book);
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
        }
      },
      itemBuilder: (context) => [
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
          await _bookService.deleteBook(book);
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.bookDeleted(book.title)),
                duration: const Duration(seconds: 2),
              ),
            );
            _loadBooks();
          }
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
          await _bookService.deleteBook(book);
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.bookDeleted(book.title)),
                duration: const Duration(seconds: 2),
              ),
            );
            _loadBooks();
          }
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
              );
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
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.menu_book,
                            size: 80,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l10n.noBooksInLibrary,
                            style: TextStyle(
                              fontSize: 20,
                              color: Colors.grey[700],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.tapToImportEpub,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadBooks,
                      child: _isListView
                          ? _buildBooksList(l10n)
                          : _buildBooksGrid(l10n),
                    ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isImporting ? null : _importEpub,
        tooltip: l10n.importEpub,
        icon: _isImporting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Icon(Icons.add),
        label: Text(_isImporting ? l10n.importing : l10n.importEpub),
      ),
    );
  }

  Widget _buildDefaultCover(Book book) {
    // Create a gradient cover with book initial
    final initial = book.title.isNotEmpty ? book.title[0].toUpperCase() : '?';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(8),
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
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

    double progressValue = progress.progress ??
        _calculateLegacyProgress(book, progress);
    progressValue = progressValue.clamp(0.0, 1.0);

    if (progressValue <= 0.0) {
      return null;
    }

    final progressPercentage = (progressValue * 100).toStringAsFixed(0);
    return _ProgressInfo(value: progressValue, label: progressPercentage);
  }

  double _calculateLegacyProgress(Book book, ReadingProgress progress) {
    final totalPages = progress.totalPages;
    final chapterIndex = (progress.currentChapterIndex ?? 0).toDouble();
    final pageInChapter = progress.currentPageInChapter ?? -1;
    final additionalPages = pageInChapter >= 0 ? (pageInChapter + 1).toDouble() : 0.0;

    if (totalPages != null && totalPages > 0) {
      final totalChapters = _bookTotalChapters[book.id];
      if (totalChapters != null && totalChapters > 0) {
        final pagesPerChapter = totalPages / totalChapters;
        final pagesRead = (chapterIndex * pagesPerChapter) + additionalPages;
        return (pagesRead / totalPages).clamp(0.0, 1.0);
      }
      const estimatedChapters = 20.0;
      final pagesPerChapter = totalPages / estimatedChapters;
      final pagesRead = (chapterIndex * pagesPerChapter) + additionalPages;
      return (pagesRead / totalPages).clamp(0.0, 1.0);
    }

    final totalChapters = _bookTotalChapters[book.id];
    if (totalChapters != null && totalChapters > 0) {
      final baseProgress = chapterIndex / totalChapters;
      final fractional = pageInChapter >= 0
          ? ((pageInChapter + 1).toDouble() / 100).clamp(0.0, 1.0) / totalChapters
          : 0.0;
      return (baseProgress + fractional).clamp(0.0, 1.0);
    }

    const estimatedTotalChapters = 20.0;
    if (estimatedTotalChapters <= 0) {
      return 0.0;
    }
    return (chapterIndex / estimatedTotalChapters).clamp(0.0, 1.0);
  }

  bool _isBookCompleted(Book book) {
    final progress = _bookProgress[book.id];
    if (progress == null) return false;

    final progressValue = (progress.progress ??
            _calculateLegacyProgress(book, progress))
        .clamp(0.0, 1.0);
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
