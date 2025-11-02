import 'dart:io';
import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import '../widgets/library_book_card.dart';

/// Main screen displaying the user's library of imported books
/// 
/// This screen shows:
/// - A grid of book covers with titles and authors
/// - Reading progress indicators for each book
/// - Options to import new EPUB files
/// - Navigation to settings and reader screens
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  // Services
  final BookService _bookService = BookService();

  // State variables
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

  /// Load all books and their reading progress
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
          // Only load for EPUB books to avoid performance issues
          // TXT and PDF chapters are calculated dynamically
          if (book.format == 'epub') {
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

  /// Import a new book file (EPUB or TXT) into the library
  Future<void> _importEpub() async {
    if (_isImporting) return;

    setState(() {
      _isImporting = true;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub', 'txt'],
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

        // Import the book (supports EPUB and TXT)
        await _bookService.importBook(file);

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

  /// Navigate to the reader screen for the selected book
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

  /// Show confirmation dialog before deleting a book
  void _showDeleteDialog(Book book) {
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
        leading: IconButton(
          icon: const Icon(Icons.menu),
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
        title: const Text(
          'Memoreader',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
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
      body: _buildBody(l10n),
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

  /// Build the main body content based on current state
  Widget _buildBody(AppLocalizations l10n) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _buildErrorView(l10n);
    }

    if (_books.isEmpty) {
      return _buildEmptyView(l10n);
    }

    return _buildBookGrid(l10n);
  }

  /// Build error view when loading fails
  Widget _buildErrorView(AppLocalizations l10n) {
    return Center(
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
    );
  }

  /// Build empty state view when no books are in library
  Widget _buildEmptyView(AppLocalizations l10n) {
    return Center(
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
    );
  }

  /// Build the grid view of books
  Widget _buildBookGrid(AppLocalizations l10n) {
    return RefreshIndicator(
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
          return LibraryBookCard(
            book: book,
            progress: _bookProgress[book.id],
            totalChapters: _bookTotalChapters[book.id],
            onTap: () => _openBook(book),
            onDelete: () => _showDeleteDialog(book),
          );
        },
      ),
    );
  }
}
