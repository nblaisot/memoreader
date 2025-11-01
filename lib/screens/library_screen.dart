import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import 'reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final BookService _bookService = BookService();
  List<Book> _books = [];
  Map<String, ReadingProgress> _bookProgress = {}; // Map bookId to progress
  Map<String, int> _bookTotalChapters = {}; // Cache total chapters per book
  bool _isLoading = true;
  bool _isImporting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadBooks();
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final file = File(filePath);
        
        if (!await file.exists()) {
          throw Exception('Selected file no longer exists');
        }
        
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
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        Navigator.pop(context); // Close progress dialog if open
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorImportingBook(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
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
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderScreen(book: book),
      ),
    ).then((_) {
      // Reload books in case reading progress changed
      _loadBooks();
    });
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.library),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
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
                      child: GridView.builder(
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
                          return Dismissible(
                            key: Key(book.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            onDismissed: (direction) {
                              _bookService.deleteBook(book).then((_) {
                                if (mounted) {
                                  _loadBooks();
                                }
                              }).catchError((e) {
                                if (mounted) {
                                  final messenger = ScaffoldMessenger.of(context);
                                  final l10n = AppLocalizations.of(context)!;
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(l10n.errorDeletingBook(e.toString())),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              });
                            },
                            confirmDismiss: (direction) async {
                              final l10n = AppLocalizations.of(context)!;
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
                              if (result == true) {
                                try {
                                  await _bookService.deleteBook(book);
                                  if (mounted) {
                                    final l10n = AppLocalizations.of(context)!;
                                    final messenger = ScaffoldMessenger.of(context);
                                    messenger.showSnackBar(
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
                                    final messenger = ScaffoldMessenger.of(context);
                                    messenger.showSnackBar(
                                      SnackBar(
                                        content: Text(l10n.errorDeletingBook(e.toString())),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                }
                              }
                              return result ?? false;
                            },
                            child: InkWell(
                              onTap: () => _openBook(book),
                              onLongPress: () => _showDeleteDialog(book, index),
                              child: Card(
                                elevation: 2,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          // Book cover
                                          Container(
                                            decoration: BoxDecoration(
                                              color: Colors.grey[200],
                                              borderRadius: const BorderRadius.vertical(
                                                top: Radius.circular(8),
                                              ),
                                            ),
                                            child: book.coverImagePath != null
                                                ? ClipRRect(
                                                    borderRadius: const BorderRadius.vertical(
                                                      top: Radius.circular(8),
                                                    ),
                                                    child: Image.network(
                                                      book.coverImagePath!,
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (context, error, stackTrace) =>
                                                          _buildDefaultCover(book),
                                                    ),
                                                  )
                                                : _buildDefaultCover(book),
                                          ),
                                          // READ watermark for completed books
                                          if (_isBookCompleted(book))
                                            Positioned.fill(
                                              child: _buildReadWatermark(),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            book.title,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            book.author,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          // Progress bar below author name
                                          _buildProgressIndicator(book),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
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
    final progress = _bookProgress[book.id];
    
    // Only show progress bar if book has been read (progress exists)
    if (progress == null) {
      return const SizedBox.shrink();
    }

    // If we're at chapter 0 and page 0, assume not started
    if (progress.currentChapterIndex == 0 && progress.currentPageInChapter == 0) {
      return const SizedBox.shrink();
    }

    // Calculate progress percentage
    double progressValue = 0.0;
    final totalChapters = _bookTotalChapters[book.id];
    
    if (totalChapters != null && totalChapters > 0) {
      // Accurate progress based on actual chapter count
      final chapterProgress = (progress.currentChapterIndex + 1) / totalChapters;
      progressValue = chapterProgress.clamp(0.0, 1.0);
      
      // If we're at the last chapter, check if we're near completion
      if (progress.currentChapterIndex >= totalChapters - 1) {
        // Assume completion if at last chapter
        progressValue = 1.0;
      }
    } else {
      // Fallback: approximate progress - assume average book has ~20 chapters
      const estimatedTotalChapters = 20.0;
      final chapterProgress = (progress.currentChapterIndex + 1) / estimatedTotalChapters;
      progressValue = chapterProgress.clamp(0.0, 1.0);
      
      // If progress is very high (>= 0.95), consider it complete
      if (progressValue >= 0.95) {
        progressValue = 1.0;
      }
    }

    final progressPercentage = (progressValue * 100).toStringAsFixed(0);

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
                    value: progressValue,
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
                '$progressPercentage%',
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

  bool _isBookCompleted(Book book) {
    final progress = _bookProgress[book.id];
    if (progress == null) return false;
    
    final totalChapters = _bookTotalChapters[book.id];
    
    if (totalChapters != null && totalChapters > 0) {
      // Book is completed if we're at or past the last chapter
      return progress.currentChapterIndex >= totalChapters - 1;
    }
    
    // Fallback: assume completion if at high chapter index (heuristic)
    const completionThreshold = 15;
    return progress.currentChapterIndex >= completionThreshold;
  }

  Widget _buildReadWatermark() {
    return Transform.rotate(
      angle: -0.5, // Rotate -28.6 degrees (roughly -0.5 radians)
      child: Container(
        color: Colors.black.withOpacity(0.6),
        child: Center(
          child: Text(
            'READ',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white.withOpacity(0.9),
              letterSpacing: 4,
            ),
          ),
        ),
      ),
    );
  }
}
