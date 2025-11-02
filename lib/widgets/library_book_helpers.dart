import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';

/// Helper functions for building library book UI components
class LibraryBookHelpers {
  /// Build a default cover with book initial and gradient
  static Widget buildDefaultCover(BuildContext context, Book book) {
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

  /// Build a reading progress indicator
  static Widget buildProgressIndicator(
    BuildContext context,
    Book book,
    ReadingProgress? progress,
    int? totalChapters,
  ) {
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

    if (totalChapters != null && totalChapters > 0) {
      // Accurate progress based on actual chapter count
      final chapterProgress = (progress.currentChapterIndex + 1) / totalChapters;
      progressValue = chapterProgress.clamp(0.0, 1.0);

      // If we're at the last chapter, assume completion
      if (progress.currentChapterIndex >= totalChapters - 1) {
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
      child: Row(
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
    );
  }

  /// Check if a book is completed based on progress
  static bool isBookCompleted(
    Book book,
    ReadingProgress? progress,
    int? totalChapters,
  ) {
    if (progress == null) return false;

    if (totalChapters != null && totalChapters > 0) {
      // Book is completed if we're at or past the last chapter
      return progress.currentChapterIndex >= totalChapters - 1;
    }

    // Fallback: assume completion if at high chapter index (heuristic)
    const completionThreshold = 15;
    return progress.currentChapterIndex >= completionThreshold;
  }

  /// Build a READ watermark overlay for completed books
  static Widget buildReadWatermark() {
    return Transform.rotate(
      angle: -0.5, // Rotate approximately -28.6 degrees
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        child: const Center(
          child: Text(
            'READ',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 4,
            ),
          ),
        ),
      ),
    );
  }
}

