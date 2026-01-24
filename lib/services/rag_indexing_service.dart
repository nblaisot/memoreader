import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/rag_chunk.dart';
import '../models/rag_index_progress.dart';
import '../services/rag_chunking_service.dart';
import '../services/rag_database_service.dart';
import '../services/rag_embedding_service.dart';
import '../services/rag_embedding_service_factory.dart';
import '../services/book_service.dart';
import '../services/settings_service.dart';

/// Simple rate limiter/semaphore for controlling concurrent batch processing
class _RateLimiter {
  final int maxConcurrent;
  int _current = 0;
  final _waitQueue = <Completer<void>>[];

  _RateLimiter(this.maxConcurrent);

  Future<void> acquire() async {
    if (_current < maxConcurrent) {
      _current++;
      return;
    }
    
    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final next = _waitQueue.removeAt(0);
      next.complete();
    } else {
      _current--;
    }
  }
}

/// Service for indexing books for RAG
/// Handles background indexing with progress tracking
/// This is a singleton to ensure all callers share the same state
class RagIndexingService {
  static RagIndexingService? _instance;

  factory RagIndexingService({
    RagDatabaseService? databaseService,
    BookService? bookService,
  }) {
    // Always return singleton instance to ensure all callers share the same state
    // (locks, controllers, isolates). The bookService parameter is stored but
    // doesn't prevent singleton behavior - this is critical for preventing race conditions.
    _instance ??= RagIndexingService._internal(
      databaseService: databaseService,
      bookService: bookService,
    );
    return _instance!;
  }

  final RagDatabaseService _databaseService;
  BookService? _bookService;
  BookService get _bookServiceInstance {
    _bookService ??= BookService();
    return _bookService!;
  }

  // Track active indexing operations
  final Map<String, Isolate> _activeIndexes = {};
  final Map<String, ReceivePort> _progressPorts = {};
  final Map<String, StreamController<RagIndexProgress>> _progressControllers = {};
  // Track books that are in the process of starting indexing (synchronous check)
  final Set<String> _startingBooks = {};

  RagIndexingService._internal({
    RagDatabaseService? databaseService,
    BookService? bookService,
  })  : _databaseService = databaseService ?? RagDatabaseService(),
        _bookService = bookService;


  /// Load current status from database and send to controller
  void _loadAndSendStatus(String bookId, StreamController<RagIndexProgress> controller) {
    _databaseService.getIndexStatus(bookId).then((status) {
      if (status != null) {
        controller.add(status);
      }
    });
  }

  /// Start indexing a book
  /// Returns a stream of progress updates
  /// This method is idempotent - safe to call multiple times
  /// The start decision is made synchronously to avoid race conditions
  Stream<RagIndexProgress> startIndexing(String bookId) {
    // Synchronous check: If already indexing, return existing stream
    if (_progressControllers.containsKey(bookId)) {
      debugPrint('[RAG] Returning existing progress stream for $bookId');
      return _progressControllers[bookId]!.stream;
    }
    
    // Synchronous check: If isolate is running but no controller, create one
    if (_activeIndexes.containsKey(bookId)) {
      debugPrint('[RAG] Isolate running for $bookId, creating new controller to receive updates');
      final controller = StreamController<RagIndexProgress>.broadcast();
      _progressControllers[bookId] = controller;
      _loadAndSendStatus(bookId, controller);
      return controller.stream;
    }
    
    // Synchronous check: If another call is starting, wait for it
    if (_startingBooks.contains(bookId)) {
      debugPrint('[RAG] Another call is starting indexing for $bookId, will wait for controller');
      // Create a temporary controller that will be replaced when the real one is created
      final tempController = StreamController<RagIndexProgress>.broadcast();
      // Poll for the real controller (will be replaced shortly)
      Future.delayed(const Duration(milliseconds: 50), () {
        if (_progressControllers.containsKey(bookId) && _progressControllers[bookId] != tempController) {
          // Real controller created, forward events
          _progressControllers[bookId]!.stream.listen(
            (progress) => tempController.add(progress),
            onError: (error) => tempController.addError(error),
            onDone: () => tempController.close(),
            cancelOnError: false,
          );
        } else if (!_progressControllers.containsKey(bookId)) {
          // Still no controller, use temp
          _progressControllers[bookId] = tempController;
        }
      });
      return tempController.stream;
    }
    
    // Synchronous decision: We're starting indexing for this book
    _startingBooks.add(bookId);
    debugPrint('[RAG] Starting indexing for book $bookId');
    
    // Create controller immediately (synchronous)
    final controller = StreamController<RagIndexProgress>.broadcast();
    _progressControllers[bookId] = controller;
    
    // Start the actual indexing work asynchronously (sequential, no race conditions)
    () async {
      try {
        // FIRST: Check database status BEFORE starting any work
        final status = await _databaseService.getIndexStatus(bookId);
        if (status?.isComplete == true) {
          debugPrint('[RAG] Indexing already complete for $bookId, returning status');
          controller.add(status!);
          // DON'T close or remove controller - keep it so future calls return it
          _startingBooks.remove(bookId);
          return;
        }
        
        // Check if isolate already running (shouldn't happen, but safety check)
        if (_activeIndexes.containsKey(bookId)) {
          debugPrint('[RAG] Isolate already running for $bookId, subscribing to updates');
          _loadAndSendStatus(bookId, controller);
          _startingBooks.remove(bookId);
          return;
        }
        
        // Start indexing isolate
        debugPrint('[RAG] Starting indexing isolate for $bookId');
        await _startIndexingIsolate(bookId);
        _startingBooks.remove(bookId);
      } catch (error) {
        debugPrint('[RAG] Failed to start indexing for book $bookId: $error');
        controller.addError(error);
        await controller.close();
        _progressControllers.remove(bookId);
        _activeIndexes.remove(bookId);
        _startingBooks.remove(bookId);
      }
    }();
    
    return controller.stream;
  }

  /// Start indexing in background isolate
  Future<void> _startIndexingIsolate(String bookId) async {
    // Safety check: verify no isolate exists
    if (_activeIndexes.containsKey(bookId)) {
      debugPrint('[RAG] WARNING: Isolate already exists for $bookId, this should not happen');
      return;
    }
    
    // Create receive port for progress updates
    final receivePort = ReceivePort();
    _progressPorts[bookId] = receivePort;

    // Get root isolate token for background messenger (may be null on some platforms)
    RootIsolateToken? rootIsolateToken;
    try {
      rootIsolateToken = RootIsolateToken.instance;
    } catch (e) {
      // RootIsolateToken may not be available, indexing will use main isolate
      debugPrint('[RAG] RootIsolateToken not available: $e');
    }

    // Get book file path (lazy initialization)
    final allBooks = await _bookServiceInstance.getAllBooks();
    final book = allBooks.firstWhere(
      (b) => b.id == bookId,
      orElse: () => throw Exception('Book not found: $bookId'),
    );

    final bookFile = File(book.filePath);

    // Spawn isolate
    debugPrint('[RAG] Spawning indexing isolate for book $bookId');
    final isolate = await Isolate.spawn(
      _indexingWorker,
      _IndexingWorkerParams(
        bookId: bookId,
        bookFilePath: bookFile.path,
        sendPort: receivePort.sendPort,
        rootIsolateToken: rootIsolateToken,
      ),
    );

    // Mark isolate as active immediately to prevent race conditions
    _activeIndexes[bookId] = isolate;
    debugPrint('[RAG] Indexing isolate started for book $bookId');

    // Listen for progress updates
    receivePort.listen((message) {
      if (message is RagIndexProgress) {
        _progressControllers[bookId]?.add(message);
      } else if (message is String && message == 'done') {
        debugPrint('[RAG] Indexing completed for book $bookId, cleaning up isolate');
        receivePort.close();
        _activeIndexes.remove(bookId);
        _progressPorts.remove(bookId);
        _startingBooks.remove(bookId);
        // DON'T close or remove controller - keep it so future calls can return completed status
        // The controller will remain with the final completed progress
      } else if (message is Map && message['error'] != null) {
        final error = message['error'] as String;
        debugPrint('[RAG] Indexing error for book $bookId: $error');
        _progressControllers[bookId]?.addError(Exception(error));
        receivePort.close();
        _activeIndexes.remove(bookId);
        _progressPorts.remove(bookId);
        _startingBooks.remove(bookId);
        _progressControllers[bookId]?.close();
        _progressControllers.remove(bookId);
      }
    });
  }

  /// Stop indexing for a book
  Future<void> stopIndexing(String bookId) async {
    final isolate = _activeIndexes[bookId];
    if (isolate != null) {
      isolate.kill(priority: Isolate.immediate);
      _activeIndexes.remove(bookId);
      _progressPorts[bookId]?.close();
      _progressPorts.remove(bookId);
      _startingBooks.remove(bookId);
      _progressControllers[bookId]?.close();
      _progressControllers.remove(bookId);
    }
  }

  /// Get current progress for a book
  Future<RagIndexProgress?> getProgress(String bookId) async {
    return await _databaseService.getIndexStatus(bookId);
  }

  /// Check if a book is currently being indexed
  bool isIndexing(String bookId) {
    return _activeIndexes.containsKey(bookId);
  }

  /// Clean up resources
  void dispose() {
    for (final isolate in _activeIndexes.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    _activeIndexes.clear();
    for (final port in _progressPorts.values) {
      port.close();
    }
    _progressPorts.clear();
    _startingBooks.clear();
    for (final controller in _progressControllers.values) {
      controller.close();
    }
    _progressControllers.clear();
  }
}

/// Parameters for indexing worker isolate
class _IndexingWorkerParams {
  final String bookId;
  final String bookFilePath;
  final SendPort sendPort;
  final RootIsolateToken? rootIsolateToken;

  _IndexingWorkerParams({
    required this.bookId,
    required this.bookFilePath,
    required this.sendPort,
    this.rootIsolateToken,
  });
}

/// Worker function for indexing (runs in isolate)
/// Must be top-level or static
void _indexingWorker(_IndexingWorkerParams params) async {
  // Initialize background isolate binary messenger for SQLite (if token available)
  if (params.rootIsolateToken != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(params.rootIsolateToken!);
  }

  final databaseService = RagDatabaseService();
  final bookFile = File(params.bookFilePath);
  RagIndexProgress? existingStatus;
  int batchesCompleted = 0; // Track batches for error reporting

  try {
    // Send initial status (no total yet)
    params.sendPort.send(
      RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.indexing,
        totalChunks: 0,
        indexedChunks: 0,
        lastUpdated: DateTime.now(),
      ),
    );

    // Resolve embedding service early so we can derive safe chunk sizes that
    // respect provider limits.
    final prefs = await SharedPreferences.getInstance();
    final embeddingService = await RagEmbeddingServiceFactory.create(prefs);

    if (embeddingService == null) {
      final errorProgress = RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.error,
        totalChunks: 0,
        indexedChunks: 0,
        lastUpdated: DateTime.now(),
        errorMessage:
            'Embedding service not available. Please configure API key.',
      );
      await databaseService.saveIndexStatus(errorProgress);
      params.sendPort.send(errorProgress);
      params.sendPort.send({'error': errorProgress.errorMessage});
      params.sendPort.send('done');
      return;
    }

    final settingsService = SettingsService();
    final configuredMinTokens = await settingsService.getRagChunkMinTokens();
    final configuredMaxTokens = await settingsService.getRagChunkMaxTokens();
    final overlapTokens = await settingsService.getRagChunkOverlapTokens();

    // Derive a safe maximum tokens per chunk based on the embedding model's
    // per-input context limit, leaving a small safety margin.
    final modelMaxTokens = embeddingService.maxTokensPerInput;
    final maxTokensPerInput = modelMaxTokens; // For validation later
    final safetyMargin = 256;
    final effectiveMaxTokens =
        (configuredMaxTokens.clamp(1, modelMaxTokens - safetyMargin));

    final chunkingService = RagChunkingService(
      minTokens: configuredMinTokens,
      maxTokens: effectiveMaxTokens,
      overlapTokens: overlapTokens,
    );

    // Chunk the book
    debugPrint('[RAG] Starting chunking for book ${params.bookId} with maxTokens=$effectiveMaxTokens (model limit: $modelMaxTokens)');
    debugPrint('[RAG] EPUB file path: ${bookFile.path}, exists: ${await bookFile.exists()}');
    final chunks = await chunkingService.chunkBook(
      epubFile: bookFile,
      bookId: params.bookId,
    );
    debugPrint('[RAG] Chunking completed, got ${chunks.length} chunks');
    debugPrint(
      '[RAG] Chunking finished: ${chunks.length} chunks. '
      'Sample ranges: ${chunks.take(3).map((c) => '(${c.charStart}-${c.charEnd})').join(', ')}',
    );
    
    // Validate chunks against embedding model limits before indexing
    int oversizedChunks = 0;
    for (final chunk in chunks) {
      final chunkTokens = chunk.tokenEnd - chunk.tokenStart;
      if (chunkTokens > maxTokensPerInput) {
        oversizedChunks++;
        debugPrint(
          '[RAG] WARNING: Chunk ${chunk.chunkId.substring(0, 8)}... exceeds model limit: '
          '$chunkTokens tokens > $maxTokensPerInput (${embeddingService.modelName})',
        );
      }
    }
    if (oversizedChunks > 0) {
      debugPrint('[RAG] Found $oversizedChunks oversized chunks that will be skipped during indexing');
    }

    if (chunks.isEmpty) {
      final errorProgress = RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.error,
        totalChunks: 0,
        indexedChunks: 0,
        lastUpdated: DateTime.now(),
        errorMessage: 'No text extracted from EPUB (0 chunks). Check chapter parsing or file content.',
      );
      await databaseService.saveIndexStatus(errorProgress);
      params.sendPort.send(errorProgress);
      params.sendPort.send({'error': errorProgress.errorMessage});
      params.sendPort.send('done');
      return;
    }

    // Send progress update with actual total chunks after chunking completes
    final totalChunks = chunks.length;
    var existingChunkCount = await databaseService.getChunkCount(params.bookId);
    if (existingChunkCount > 0 && existingChunkCount != totalChunks) {
      debugPrint(
        '[RAG] Detected inconsistent chunk count for ${params.bookId}: '
        '$existingChunkCount/$totalChunks. Clearing and re-indexing.',
      );
      await databaseService.clearBook(params.bookId);
      existingChunkCount = 0;
    }
    final chunkingProgress = RagIndexProgress(
      bookId: params.bookId,
      status: RagIndexStatus.indexing,
      totalChunks: totalChunks,
      indexedChunks: existingChunkCount,
      lastUpdated: DateTime.now(),
    );
    await databaseService.saveIndexStatus(chunkingProgress);
    params.sendPort.send(chunkingProgress);

    // Check embedding dimensions match
    existingStatus = await databaseService.getIndexStatus(params.bookId);
    if (existingStatus != null &&
        existingStatus.embeddingDimension != null &&
        existingStatus.embeddingDimension != 0 &&
        existingStatus.embeddingDimension != embeddingService.embeddingDimensions) {
      throw Exception(
        'Embedding dimension mismatch. Existing: ${existingStatus.embeddingDimension}, '
        'Current: ${embeddingService.embeddingDimensions}. Please clear RAG database.',
      );
    }

    // Update index status with embedding model info (totalChunks already set above)
    await databaseService.saveIndexStatus(
      RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.indexing,
        totalChunks: totalChunks,
        indexedChunks: existingChunkCount,
        lastUpdated: DateTime.now(),
        embeddingModel: embeddingService.modelName,
        embeddingDimension: embeddingService.embeddingDimensions,
      ),
    );
    
    // Send progress update with embedding model info
    params.sendPort.send(
      RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.indexing,
        totalChunks: totalChunks,
        indexedChunks: existingChunkCount,
        lastUpdated: DateTime.now(),
        embeddingModel: embeddingService.modelName,
        embeddingDimension: embeddingService.embeddingDimensions,
      ),
    );

    // Filter out already-indexed chunks (idempotency) - batch check for performance
    final chunkRanges = chunks.map((c) => (c.charStart, c.charEnd)).toList();
    debugPrint('[RAG] Checking for existing chunks: ${chunkRanges.length} total chunks');
    debugPrint('[RAG] Sample chunk ranges (first 3): ${chunkRanges.take(3).map((r) => '(${r.$1}-${r.$2})').join(', ')}');
    final existingChunks = await databaseService.chunksExist(params.bookId, chunkRanges);
    debugPrint('[RAG] Found ${existingChunks.length} existing chunks out of ${chunkRanges.length} total');
    if (existingChunks.isNotEmpty) {
      debugPrint('[RAG] Sample existing chunks (first 3): ${existingChunks.take(3).map((r) => '(${r.$1}-${r.$2})').join(', ')}');
    }
    // Also check total chunk count in database
    final dbChunkCount = await databaseService.getChunkCount(params.bookId);
    debugPrint('[RAG] Total chunks in database for this book: $dbChunkCount');
    final chunksToIndex = chunks.where((chunk) {
      return !existingChunks.contains((chunk.charStart, chunk.charEnd));
    }).toList();
    debugPrint('[RAG] Chunks to index: ${chunksToIndex.length} (${existingChunkCount} already indexed)');

    if (chunksToIndex.isEmpty) {
      debugPrint('[RAG] All chunks already indexed for ${params.bookId}, skipping embedding calls');
      final completedProgress = RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.completed,
        totalChunks: totalChunks,
        indexedChunks: existingChunkCount,
        lastUpdated: DateTime.now(),
        embeddingModel: embeddingService.modelName,
        embeddingDimension: embeddingService.embeddingDimensions,
        apiCalls: 0,
      );

      await databaseService.saveIndexStatus(completedProgress);
      params.sendPort.send(completedProgress);
      params.sendPort.send('done');
      return;
    }

    // Index chunks in batches with dynamic batch sizing
    // Use embedding service's actual limits for accurate batch sizing
    final configuredBatchSize = await settingsService.getRagBatchSize();
    final maxConcurrentBatches = await settingsService.getRagConcurrentBatches();
    final progressUpdateFrequency = await settingsService.getRagProgressUpdateFrequency();
    
    // Use configured batch size if set, otherwise use provider defaults
    // For mobile, use conservative defaults to avoid memory pressure
    // IMPORTANT: Limit batch size to ensure progress updates are visible
    // Even if chunks fit in one batch, we want multiple batches for progress feedback
    final maxBatchSize = configuredBatchSize > 0
        ? configuredBatchSize.clamp(1, 100) // Cap at 100 chunks per batch for progress visibility
        : 50; // Default to 50 chunks per batch for better progress granularity
    const maxTokensPerBatch = 300000; // OpenAI total batch limit
    // maxTokensPerInput is already declared earlier for validation
    
    int indexedCount = existingChunkCount;
    bool hadFailures = false;
    int skippedChunks = 0;
    int currentIndex = 0;
    final List<String> errorDetails = []; // Track specific error details
    batchesCompleted = 0; // Reset for this indexing run
    
    // Parallel batch processing with rate limiting
    final activeBatches = <Future<void>>{};
    final semaphore = _RateLimiter(maxConcurrentBatches);

    while (currentIndex < chunksToIndex.length || activeBatches.isNotEmpty) {
      // Start new batches up to concurrency limit
      while (currentIndex < chunksToIndex.length && activeBatches.length < maxConcurrentBatches) {
        // Calculate optimal batch size based on token count
        final batchSize = _calculateOptimalBatchSize(
          chunksToIndex,
          currentIndex,
          maxBatchSize,
          maxTokensPerBatch,
          maxTokensPerInput,
        );
        
        if (batchSize == 0) {
          // Single chunk exceeds token limit - skip it with error
          final chunk = chunksToIndex[currentIndex];
          final chunkTokens = chunk.tokenEnd - chunk.tokenStart;
          final errorMsg = 'Chunk exceeds ${embeddingService.modelName} limit: $chunkTokens tokens > $maxTokensPerInput max';
          debugPrint('[RAG] ERROR: $errorMsg (chunk ${currentIndex + 1}/${chunksToIndex.length})');
          errorDetails.add(errorMsg);
          skippedChunks++;
          hadFailures = true;
          currentIndex++;
          continue;
        }
        
        final batch = chunksToIndex.sublist(
          currentIndex,
          currentIndex + batchSize,
        );
        currentIndex += batchSize;

        // Process batch asynchronously with rate limiting
        final batchFuture = semaphore.acquire().then((_) async {
          try {
            // Generate embeddings with retry logic
            List<Float32List> embeddings = [];
            try {
              embeddings = await _generateEmbeddingsWithRetry(
                embeddingService,
                batch.map((c) => c.text).toList(),
              );
            } catch (e) {
              final errorMsg = 'Embedding generation failed: ${e.toString()}';
              debugPrint('[RAG] ERROR: $errorMsg (batch of ${batch.length} chunks)');
              errorDetails.add(errorMsg);
              hadFailures = true;
              return;
            }

            // Update chunks with embeddings
            final chunksWithEmbeddings = <RagChunk>[];
            for (int j = 0; j < batch.length && j < embeddings.length; j++) {
              chunksWithEmbeddings.add(
                batch[j].copyWith(
                  embedding: embeddings[j],
                  embeddingDimension: embeddingService.embeddingDimensions,
                ),
              );
            }

            // Save chunks to database
            debugPrint('[RAG] Saving ${chunksWithEmbeddings.length} chunks to database for book ${params.bookId}');
            await databaseService.saveChunks(chunksWithEmbeddings);
            debugPrint('[RAG] Chunks saved successfully');
            
            // Get the count BEFORE clearing (this was the bug!)
            final savedCount = chunksWithEmbeddings.length;
            
            // Clear embeddings from memory to reduce RAM usage
            chunksWithEmbeddings.clear();
            embeddings.clear();
            
            // Verify chunks were actually saved
            final verifyCount = await databaseService.getChunkCount(params.bookId);
            debugPrint('[RAG] Verified chunk count in database after save: $verifyCount');
            
            final newIndexedCount = await databaseService.incrementIndexedChunks(
              params.bookId,
              savedCount,
            );
            debugPrint('[RAG] Incremented indexed chunks: $savedCount, new total: $newIndexedCount');

            // Update progress
            final progress = RagIndexProgress(
              bookId: params.bookId,
              status: RagIndexStatus.indexing,
              totalChunks: totalChunks,
              indexedChunks: newIndexedCount,
              lastUpdated: DateTime.now(),
              embeddingModel: embeddingService.modelName,
              embeddingDimension: embeddingService.embeddingDimensions,
            );

            // Always save progress to database for accuracy and resume capability
            await databaseService.saveIndexStatus(progress);
            
            // Send progress updates more frequently for better UX
            // Update every batch if frequency is 1, otherwise throttle based on batch count
            batchesCompleted++;
            final shouldSendUpdate = progressUpdateFrequency == 1 || 
                                     batchesCompleted % progressUpdateFrequency == 0 ||
                                     batchesCompleted == 1;
            
            debugPrint('[RAG] Batch completed: $batchesCompleted, indexedChunks: $newIndexedCount/$totalChunks, shouldSendUpdate: $shouldSendUpdate');
            
            if (shouldSendUpdate) {
              debugPrint('[RAG] Sending progress update: $newIndexedCount/$totalChunks (${((newIndexedCount / totalChunks) * 100).toStringAsFixed(1)}%)');
              params.sendPort.send(progress);
            }
            
            // Update local counter for final check
            indexedCount = newIndexedCount;
          } finally {
            semaphore.release();
          }
        });
        
        // Add to active batches and remove when complete
        activeBatches.add(batchFuture);
        batchFuture.whenComplete(() {
          activeBatches.remove(batchFuture);
        });
      }
      
      // Wait for at least one batch to complete before starting more
      if (activeBatches.isNotEmpty) {
        await Future.any(activeBatches);
      }
    }
    
    // Wait for all remaining batches to complete
    if (activeBatches.isNotEmpty) {
      debugPrint('[RAG] Waiting for ${activeBatches.length} remaining batches to complete');
      await Future.wait(activeBatches.toList());
      debugPrint('[RAG] All batches completed');
    }
    
    // Get final count from database for accuracy and ensure progress is up to date
    final finalChunkCount = await databaseService.getChunkCount(params.bookId);
    debugPrint('[RAG] Final chunk count in database: $finalChunkCount (expected: $totalChunks)');
    final finalStatus = await databaseService.getIndexStatus(params.bookId);
    indexedCount = finalStatus?.indexedChunks ?? indexedCount;
    debugPrint('[RAG] Final indexed count from status: $indexedCount');
    debugPrint('[RAG] Final stats for ${params.bookId}: indexed=$indexedCount/$totalChunks, batches=$batchesCompleted, dbCount=$finalChunkCount');
    
    // Always send final progress update to ensure UI is up to date
    final finalProgress = RagIndexProgress(
      bookId: params.bookId,
      status: RagIndexStatus.indexing,
      totalChunks: totalChunks,
      indexedChunks: indexedCount,
      lastUpdated: DateTime.now(),
      embeddingModel: embeddingService.modelName,
      embeddingDimension: embeddingService.embeddingDimensions,
      skippedChunks: skippedChunks > 0 ? skippedChunks : null,
      apiCalls: batchesCompleted,
    );
    await databaseService.saveIndexStatus(finalProgress);
    params.sendPort.send(finalProgress);

    if (hadFailures) {
      // Build detailed error message
      final errorParts = <String>[];
      if (skippedChunks > 0) {
        errorParts.add('$skippedChunks chunk${skippedChunks > 1 ? 's' : ''} skipped');
      }
      if (errorDetails.isNotEmpty) {
        final uniqueErrors = errorDetails.toSet().take(3).join('; ');
        if (errorDetails.length > 3) {
          errorParts.add('$uniqueErrors (+${errorDetails.length - 3} more)');
        } else {
          errorParts.add(uniqueErrors);
        }
      }
      final errorMessage = errorParts.isEmpty
          ? 'Indexing incomplete due to errors'
          : 'Indexing incomplete: ${errorParts.join('. ')}';
      
      debugPrint('[RAG] Indexing completed with errors: $errorMessage');
      
      final errorProgress = RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.error,
        totalChunks: totalChunks,
        indexedChunks: indexedCount,
        lastUpdated: DateTime.now(),
        errorMessage: errorMessage,
        embeddingModel: embeddingService.modelName,
        embeddingDimension: embeddingService.embeddingDimensions,
        skippedChunks: skippedChunks > 0 ? skippedChunks : null,
        apiCalls: batchesCompleted,
      );

      await databaseService.saveIndexStatus(errorProgress);
      params.sendPort.send(errorProgress);
      params.sendPort.send({'error': errorProgress.errorMessage});
      params.sendPort.send('done');
      return;
    }

    // Mark as completed (with skipped chunks info if any)
    final completedProgress = RagIndexProgress(
      bookId: params.bookId,
      status: RagIndexStatus.completed,
      totalChunks: totalChunks,
      indexedChunks: indexedCount,
      lastUpdated: DateTime.now(),
      embeddingModel: embeddingService.modelName,
      embeddingDimension: embeddingService.embeddingDimensions,
      skippedChunks: skippedChunks > 0 ? skippedChunks : null,
      apiCalls: batchesCompleted,
    );

    await databaseService.saveIndexStatus(completedProgress);
    params.sendPort.send(completedProgress);
    params.sendPort.send('done');
  } catch (e, stackTrace) {
    debugPrint('[RAG] Indexing error: $e');
    debugPrint('[RAG] Stack trace: $stackTrace');
    
    // Get current status to preserve totalChunks and skippedChunks if available
    final currentStatus = await databaseService.getIndexStatus(params.bookId);
    final totalChunks = currentStatus?.totalChunks ?? 0;
    final existingSkipped = currentStatus?.skippedChunks ?? 0;
    
    // Update status with error
    final errorProgress = RagIndexProgress(
      bookId: params.bookId,
      status: RagIndexStatus.error,
      totalChunks: totalChunks,
      indexedChunks: currentStatus?.indexedChunks ?? 0,
      lastUpdated: DateTime.now(),
      errorMessage: e.toString(),
      embeddingModel: existingStatus?.embeddingModel ?? currentStatus?.embeddingModel,
      embeddingDimension: existingStatus?.embeddingDimension ?? currentStatus?.embeddingDimension,
      skippedChunks: existingSkipped > 0 ? existingSkipped : null,
      apiCalls: batchesCompleted,
    );

    await databaseService.saveIndexStatus(errorProgress);
    params.sendPort.send(errorProgress);
    params.sendPort.send({'error': e.toString()});
    params.sendPort.send('done');
  }
}

/// Generate embeddings with retry logic and exponential backoff
Future<List<Float32List>> _generateEmbeddingsWithRetry(
  EmbeddingService embeddingService,
  List<String> texts,
) async {
  int maxRetries = 5; // Increased from 3 for better resilience
  int attempt = 0;
  Duration delay = const Duration(seconds: 2);

  while (attempt < maxRetries) {
    try {
      return await embeddingService.embedTexts(texts);
    } on EmbeddingRateLimitException catch (e) {
      attempt++;
      
      // Use retry-after from API if available, otherwise exponential backoff
      if (e.retryAfterSeconds != null) {
        delay = Duration(seconds: e.retryAfterSeconds!);
        debugPrint('[RAG] Rate limit hit. API suggests retry after ${e.retryAfterSeconds}s (attempt $attempt/$maxRetries)');
      } else {
        // Exponential backoff: 2s, 4s, 8s, 16s, 32s
        debugPrint('[RAG] Rate limit hit. Using exponential backoff: ${delay.inSeconds}s (attempt $attempt/$maxRetries)');
      }
      
      if (attempt >= maxRetries) {
        debugPrint('[RAG] Max retries exceeded after rate limiting');
        rethrow;
      }
      
      await Future.delayed(delay);
      
      // Double the delay for next retry if not using API-provided value
      if (e.retryAfterSeconds == null) {
        delay = Duration(seconds: delay.inSeconds * 2);
      }
    } on SocketException catch (e) {
      // Network connectivity issue
      attempt++;
      debugPrint('[RAG] Network error: ${e.message} (attempt $attempt/$maxRetries)');
      
      if (attempt >= maxRetries) {
        debugPrint('[RAG] Max retries exceeded after network errors');
        rethrow;
      }
      
      // For network errors, use linear backoff
      await Future.delayed(Duration(seconds: 2 * attempt));
    } catch (e) {
      // Other errors - don't retry
      debugPrint('[RAG] Non-retryable error during embedding generation: $e');
      rethrow;
    }
  }

  throw Exception('Failed to generate embeddings after $maxRetries attempts');
}

/// Calculate optimal batch size based on token count
/// Returns the number of chunks that fit within token and count limits
int _calculateOptimalBatchSize(
  List<RagChunk> chunks,
  int startIndex,
  int maxBatchSize,
  int maxTokensPerBatch,
  int maxTokensPerInput,
) {
  if (startIndex >= chunks.length) return 0;
  
  int tokenCount = 0;
  int batchSize = 0;
  
  // Import tokenizer function
  final tokenize = (String text) {
    // Simple token estimation: ~4 characters per token (conservative)
    // For more accuracy, we could use the actual tokenizer, but this is faster
    return (text.length / 4).ceil();
  };
  
  for (int i = startIndex; i < chunks.length && batchSize < maxBatchSize; i++) {
    final chunk = chunks[i];
    // Use stored token count if available, otherwise estimate
    final chunkTokens = chunk.tokenEnd > chunk.tokenStart
        ? (chunk.tokenEnd - chunk.tokenStart)
        : tokenize(chunk.text);
    
    // Check per-input limit first (e.g., 8192 for OpenAI)
    if (chunkTokens > maxTokensPerInput) {
      // Single chunk exceeds per-input limit - return 0 to signal error
      // This is a deterministic error that should be caught during chunking
      debugPrint(
        '[RAG] ERROR: Chunk at index $i exceeds per-input token limit: '
        '$chunkTokens tokens > $maxTokensPerInput max. '
        'Chunk will be skipped. Consider reducing maxRagChunkTokens setting.',
      );
      return 0;
    }
    
    // Check total batch limit
    if (tokenCount + chunkTokens > maxTokensPerBatch) {
      break;
    }
    
    tokenCount += chunkTokens;
    batchSize++;
  }
  
  return batchSize;
}
