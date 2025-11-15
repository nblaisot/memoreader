import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import '../services/enhanced_summary_service.dart';
import '../services/summary_config_service.dart';
import '../services/settings_service.dart';
import '../services/summary_database_service.dart';

/// Service for proactive background summary generation
/// 
/// This service generates summaries in the background to minimize user wait time.
/// It tracks generation state and only generates when necessary.
class BackgroundSummaryService {
  static final BackgroundSummaryService _instance = BackgroundSummaryService._internal();
  factory BackgroundSummaryService() => _instance;
  BackgroundSummaryService._internal();

  final BookService _bookService = BookService();
  final SettingsService _settingsService = SettingsService();
  final SummaryDatabaseService _dbService = SummaryDatabaseService();
  final Map<String, Completer<void>> _generationCompleters = {};
  final Map<String, bool> _generationInProgress = {};
  EnhancedSummaryService? _summaryService;
  bool _isInitialized = false;

  /// Initialize the service with summary service
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final configService = SummaryConfigService(prefs);
      final baseService = await configService.getSummaryService();
      
      if (baseService != null) {
        _summaryService = EnhancedSummaryService(baseService, prefs);
        _isInitialized = true;
      }
    } catch (e) {
      debugPrint('Failed to initialize BackgroundSummaryService: $e');
    }
  }

  /// Check if summary generation is currently in progress for a book
  bool isGenerationInProgress(String bookId) {
    return _generationInProgress[bookId] ?? false;
  }

  /// Generate summaries proactively for a book
  /// Returns immediately - all checks and generation happen asynchronously in background
  /// This method is completely non-blocking
  void generateSummariesIfNeeded(
    Book book,
    ReadingProgress progress,
    String languageCode,
  ) {
    // Run everything in a microtask to ensure it's truly non-blocking
    Future.microtask(() async {
      // Initialize if not already done (async, but non-blocking for caller)
      if (!_isInitialized) {
        await initialize();
      }

      // Check if summary service is available
      if (_summaryService == null) {
        debugPrint('Summary service not available for background generation');
        return;
      }

      final bookId = book.id;
      
      // Check if generation is already in progress
      if (_generationInProgress[bookId] == true) {
        debugPrint('Summary generation already in progress for book: ${book.id}');
        return;
      }

      // Check if generation is needed (async DB check, but non-blocking for caller)
      final needsGeneration = await _needsGeneration(book, progress);
      if (!needsGeneration) {
        debugPrint('Summary generation not needed for book: ${book.id}');
        return;
      }

      // Start generation in background (completely fire-and-forget)
      _startBackgroundGeneration(book, progress, languageCode);
    }).catchError((error) {
      debugPrint('Error in generateSummariesIfNeeded: $error');
    });
  }

  /// Check if summary generation is needed
  Future<bool> _needsGeneration(Book book, ReadingProgress progress) async {
    try {
      final currentCharIndex = progress.currentCharacterIndex;
      final currentWordIndex = progress.currentWordIndex;
      final currentChunkIndex = currentCharIndex != null
          ? EnhancedSummaryService.computeChunkIndexForCharacterStatic(currentCharIndex)
          : currentWordIndex != null
              ? EnhancedSummaryService.computeChunkIndexForCharacterStatic(currentWordIndex * 6)
              : progress.currentChapterIndex ?? 0;

      final hasProgress = (currentCharIndex != null && currentCharIndex > 0) ||
          (currentWordIndex != null && currentWordIndex > 0) ||
          currentChunkIndex > 0;

      // If no progress, no generation needed
      if (!hasProgress) {
        return false;
      }

      // Check if we have up-to-date summaries
      final cache = await _dbService.getSummaryCache(book.id);
      if (cache != null) {
        bool summaryUpToDate;
        if (currentCharIndex != null) {
          summaryUpToDate = cache.lastProcessedCharacterIndex != null &&
              cache.lastProcessedCharacterIndex! >= currentCharIndex &&
              cache.cumulativeSummary.isNotEmpty;
        } else if (currentWordIndex != null) {
          summaryUpToDate = cache.lastProcessedWordIndex != null &&
              cache.lastProcessedWordIndex! >= currentWordIndex &&
              cache.cumulativeSummary.isNotEmpty;
        } else {
          summaryUpToDate = cache.lastProcessedChunkIndex >= currentChunkIndex &&
              cache.cumulativeSummary.isNotEmpty;
        }

        bool charactersUpToDate;
        if (currentCharIndex != null) {
          charactersUpToDate = cache.charactersSummaryCharacterIndex != null &&
              cache.charactersSummaryCharacterIndex! >= currentCharIndex &&
              cache.charactersSummary != null &&
              cache.charactersSummary!.isNotEmpty;
        } else if (currentWordIndex != null) {
          charactersUpToDate = cache.charactersSummaryWordIndex != null &&
              cache.charactersSummaryWordIndex! >= currentWordIndex &&
              cache.charactersSummary != null &&
              cache.charactersSummary!.isNotEmpty;
        } else {
          charactersUpToDate = cache.charactersSummaryChunkIndex != null &&
              cache.charactersSummaryChunkIndex! >= currentChunkIndex &&
              cache.charactersSummary != null &&
              cache.charactersSummary!.isNotEmpty;
        }

        // If both are up to date, no generation needed
        if (summaryUpToDate && charactersUpToDate) {
          return false;
        }
      }
      
      // Generation needed if we have progress but no cache, or cache is outdated
      return true;
    } catch (e) {
      debugPrint('Error checking if generation needed: $e');
      return false;
    }
  }

  /// Start background generation for a book
  void _startBackgroundGeneration(
    Book book,
    ReadingProgress progress,
    String languageCode,
  ) {
    final bookId = book.id;
    _generationInProgress[bookId] = true;
    
    // Create completer to track generation
    final completer = Completer<void>();
    _generationCompleters[bookId] = completer;

    // Generate in background (fire and forget, but track state)
    _generateSummaries(book, progress, languageCode).then((_) {
      _generationInProgress[bookId] = false;
      _generationCompleters.remove(bookId);
      if (!completer.isCompleted) {
        completer.complete();
      }
      debugPrint('Background summary generation completed for book: ${book.id}');
    }).catchError((error) {
      _generationInProgress[bookId] = false;
      _generationCompleters.remove(bookId);
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      debugPrint('Background summary generation failed for book: ${book.id}: $error');
    });
  }

  /// Generate all summaries for a book
  Future<void> _generateSummaries(
    Book book,
    ReadingProgress progress,
    String languageCode,
  ) async {
    if (_summaryService == null) return;

    try {
      // Generate cumulative summary (from beginning)
      await _summaryService!.getSummaryUpToPosition(
        book,
        progress,
        languageCode,
      );

      // Generate characters summary
      await _summaryService!.getCharactersSummary(
        book,
        progress,
        languageCode,
      );

      // Note: We don't generate "since last time" proactively as it depends on
      // when the user last stopped reading, which may change
    } catch (e) {
      debugPrint('Error generating summaries in background: $e');
      rethrow;
    }
  }

  /// Wait for generation to complete (if in progress)
  Future<void> waitForGeneration(String bookId) async {
    final completer = _generationCompleters[bookId];
    if (completer != null && !completer.isCompleted) {
      try {
        await completer.future;
      } catch (e) {
        // Ignore errors, generation will be retried when user opens summary screen
        debugPrint('Error waiting for generation: $e');
      }
    }
  }

  /// Generate summaries for all books that need it
  /// Called when app comes to foreground
  Future<void> generateSummariesForAllBooks(String languageCode) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_summaryService == null) {
      return;
    }

    try {
      final books = await _bookService.getAllBooks();
      
      for (final book in books) {
        final progress = await _bookService.getReadingProgress(book.id);
        if (progress != null && progress.currentChapterIndex != null && progress.currentChapterIndex! > 0) {
          // Generate in background without waiting
          generateSummariesIfNeeded(book, progress, languageCode);
        }
      }
    } catch (e) {
      debugPrint('Error generating summaries for all books: $e');
    }
  }
}

