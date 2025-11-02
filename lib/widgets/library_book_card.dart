import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import 'library_book_helpers.dart';

/// Card widget displaying a single book in the library grid
/// 
/// Shows:
/// - Book cover (image or generated with initial)
/// - Book title and author
/// - Reading progress indicator
/// - Delete option via menu
class LibraryBookCard extends StatelessWidget {
  final Book book;
  final ReadingProgress? progress;
  final int? totalChapters;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const LibraryBookCard({
    super.key,
    required this.book,
    this.progress,
    this.totalChapters,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
      confirmDismiss: (direction) async {
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
          onDelete();
        }
        return result ?? false;
      },
      child: InkWell(
        onTap: onTap,
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Book cover section
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Book cover image or default
                    _buildCover(context),
                    // READ watermark for completed books
                    if (LibraryBookHelpers.isBookCompleted(book, progress, totalChapters))
                      Positioned.fill(
                        child: LibraryBookHelpers.buildReadWatermark(),
                      ),
                    // Menu button at top right
                    _buildMenuButton(context, l10n),
                  ],
                ),
              ),
              // Book info section
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
                    // Progress indicator below author
                    LibraryBookHelpers.buildProgressIndicator(
                      context,
                      book,
                      progress,
                      totalChapters,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build the book cover (image or default with initial)
  Widget _buildCover(BuildContext context) {
    return Container(
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
                    LibraryBookHelpers.buildDefaultCover(context, book),
              ),
            )
          : LibraryBookHelpers.buildDefaultCover(context, book),
    );
  }

  /// Build the menu button at top right of cover
  Widget _buildMenuButton(BuildContext context, AppLocalizations l10n) {
    return Positioned(
      top: 8,
      right: 8,
      child: PopupMenuButton<String>(
        icon: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.more_vert,
            size: 18,
            color: Colors.black87,
          ),
        ),
        onSelected: (value) {
          if (value == 'delete') {
            onDelete();
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
      ),
    );
  }
}

