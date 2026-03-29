import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memoreader/models/book.dart';

/// Renders a book cover from disk, or a gradient placeholder.
///
/// Invalid books ([Book.isValid] false) never use [Image.file], so after a
/// Drive download the widget tree does not recycle a [FileImage] stuck in an
/// error state from when the file was missing.
class BookCoverImage extends StatelessWidget {
  const BookCoverImage({super.key, required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    if (!book.isValid) {
      return BookDefaultCover(book: book);
    }
    if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty) {
      final file = File(book.coverImagePath!);
      Object keyPart = 0;
      try {
        if (file.existsSync()) {
          final stat = file.statSync();
          keyPart = Object.hash(
            stat.size,
            stat.modified.millisecondsSinceEpoch,
          );
        }
      } catch (_) {}
      return Image.file(
        file,
        key: ValueKey('cover_${book.id}_${book.isValid}_$keyPart'),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          debugPrint('Error loading cover image: $error');
          return BookDefaultCover(book: book);
        },
      );
    }
    return BookDefaultCover(book: book);
  }
}

class BookDefaultCover extends StatelessWidget {
  const BookDefaultCover({super.key, required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
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
}
