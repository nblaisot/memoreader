import 'rag_background_jobs.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
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
import '../services/canonical_book_text_service.dart';
import '../services/embedding_capability_service.dart';
import '../models/book.dart';

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
  final Map<String, StreamController<RagIndexProgress>> _progressControllers =
      {};
  // Track books that are in the process of starting indexing (synchronous check)
  final Set<String> _startingBooks = {};

  RagIndexingService._internal({
    RagDatabaseService? databaseService,
    BookService? bookService,
  }) : _databaseService = databaseService ?? RagDatabaseService(),
       _bookService = bookService;

  /// Synced book metadata can exist before its EPUB is downloaded. Only a
  /// regular, non-empty local file can be indexed.
  static Future<bool> hasLocalBookFile(Book book) async {
    if (book.filePath.isEmpty) return false;
    try {
      final file = File(book.filePath);
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  final _changes = StreamController<RagIndexProgress>.broadcast();
  final Map<String, RagIndexProgress> _snapshots = {};
  final _bookLimiter = _RateLimiter(1);
  final _leaseOwner = '$pid:${DateTime.now().microsecondsSinceEpoch}';
  int interactiveQueries = 0;
  final Set<String> _heldSlots = {};
  final Set<String> _leasedBooks = {};
  final Set<String> _rerunBooks = {};
  Isolate? _workerIsolate;
  SendPort? _workerRequests;
  void _releaseSlot(String bookId) {
    if (!_heldSlots.remove(bookId)) return;
    () async {
      try {
        if (_leasedBooks.remove(bookId)) {
          await _databaseService.releaseLease(bookId, _leaseOwner);
        }
      } catch (e) {
        debugPrint('[RAG] Lease release failed: ${e.runtimeType}');
      } finally {
        _bookLimiter.release();
      }
    }();
  }

  Future<void> _recordFailure(String bookId, Object error) async {
    if (_snapshots[bookId]?.isComplete == true) return;
    final failed = RagIndexProgress(
      bookId: bookId,
      status: RagIndexStatus.error,
      totalChunks: _snapshots[bookId]?.totalChunks ?? 0,
      indexedChunks: _snapshots[bookId]?.indexedChunks ?? 0,
      lastUpdated: DateTime.now(),
      errorMessage: error.toString(),
    );
    _snapshots[bookId] = failed;
    _changes.add(failed);
    try {
      await _databaseService.saveIndexStatus(failed);
    } catch (_) {
      /* Retry remains available even when storage initialization failed. */
    }
  }

  RagIndexProgress? snapshot(String bookId) => _snapshots[bookId];

  /// Observing never queues work. Subscribe before loading to avoid missed events.
  Stream<RagIndexProgress> observe(String bookId) => Stream.multi((sink) {
    var cancelled = false;
    final sub = _changes.stream
        .where((p) => p.bookId == bookId)
        .listen(sink.add, onError: sink.addError);
    final cached = _snapshots[bookId];
    if (cached != null) {
      sink.add(cached);
    } else {
      () async {
        try {
          final stored =
              await _databaseService.getActiveIndexStatus(bookId) ??
              await _databaseService.getIndexStatus(bookId);
          if (!cancelled && stored != null) {
            final latest = _snapshots.putIfAbsent(bookId, () => stored);
            sink.add(latest);
          }
        } catch (e, st) {
          if (!cancelled) sink.addError(e, st);
        }
      }();
    }
    sink.onCancel = () async {
      cancelled = true;
      await sub.cancel();
    };
  });

  Future<String> _configurationIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final embedding = await RagEmbeddingServiceFactory.create(prefs);
    final settings = SettingsService();
    return '${embedding?.providerName}:${embedding?.modelName}:${embedding?.embeddingDimensions}:${RagChunkingService.chunkingVersion}:${RagDatabaseService.indexVersion}:${await settings.getRagChunkMinTokens()}:${await settings.getRagChunkMaxTokens()}:${await settings.getRagChunkOverlapTokens()}';
  }

  Future<bool> _alreadyReady(String bookId) async {
    final book = (await _bookServiceInstance.getAllBooks())
        .where((b) => b.id == bookId)
        .firstOrNull;
    if (book == null || !await hasLocalBookFile(book)) return false;
    final stat = await File(book.filePath).stat();
    final job = await _databaseService.getJob(bookId);
    final active = await _databaseService.getActiveIndexStatus(bookId);
    if (active == null || job == null || job['state'] != 'ready') {
      _snapshots.remove(bookId);
      return false;
    }
    final configuration = await _configurationIdentity();
    final sameFile =
        job['fileSize'] == stat.size &&
        job['fileModified'] == stat.modified.millisecondsSinceEpoch;
    final identityPrefix = configuration.split(':').take(3).join(':');
    final compatible =
        sameFile &&
        (job['configIdentity'] as String? ?? '').startsWith('$identityPrefix:');
    final ready = compatible && job['configIdentity'] == configuration;
    if (compatible) {
      _snapshots[bookId] = active;
      _changes.add(active);
    } else {
      _snapshots.remove(bookId);
    }
    return ready;
  }

  Future<void> recover({
    bool waitForCompletion = false,
    bool configurationChanged = false,
  }) async {
    for (final book in await _bookServiceInstance.getAllBooks()) {
      if (!await hasLocalBookFile(book)) continue;
      if (configurationChanged && _progressControllers.containsKey(book.id)) {
        _rerunBooks.add(book.id);
      }
      final stream = startIndexing(book.id);
      if (waitForCompletion) {
        await stream.drain<void>();
      } else {
        stream.listen(
          (_) {},
          onError: (Object e) {
            debugPrint('[RAG] Preparation failed: ${e.runtimeType}');
          },
        );
      }
    }
  }

  /// Load current status from database and send to controller
  void _loadAndSendStatus(
    String bookId,
    StreamController<RagIndexProgress> controller,
  ) {
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
      debugPrint(
        '[RAG] Isolate running for $bookId, creating new controller to receive updates',
      );
      final controller = StreamController<RagIndexProgress>.broadcast();
      _progressControllers[bookId] = controller;
      _loadAndSendStatus(bookId, controller);
      return controller.stream;
    }

    // Synchronous check: If another call is starting, wait for it
    if (_startingBooks.contains(bookId)) {
      debugPrint(
        '[RAG] Another call is starting indexing for $bookId, will wait for controller',
      );
      // Create a temporary controller that will be replaced when the real one is created
      final tempController = StreamController<RagIndexProgress>.broadcast();
      // Poll for the real controller (will be replaced shortly)
      Future.delayed(const Duration(milliseconds: 50), () {
        if (_progressControllers.containsKey(bookId) &&
            _progressControllers[bookId] != tempController) {
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
        // Check if isolate already running (shouldn't happen, but safety check)
        if (_activeIndexes.containsKey(bookId)) {
          debugPrint(
            '[RAG] Isolate already running for $bookId, subscribing to updates',
          );
          _loadAndSendStatus(bookId, controller);
          _startingBooks.remove(bookId);
          return;
        }

        final local = (await _bookServiceInstance.getAllBooks())
            .where((b) => b.id == bookId)
            .firstOrNull;
        if (local == null || !await hasLocalBookFile(local)) {
          _startingBooks.remove(bookId);
          _progressControllers.remove(bookId);
          await controller.close();
          return;
        }
        if (await _alreadyReady(bookId)) {
          controller.add(_snapshots[bookId]!);
          _startingBooks.remove(bookId);
          _progressControllers.remove(bookId);
          await controller.close();
          return;
        }
        final pending = RagIndexProgress(
          bookId: bookId,
          status: RagIndexStatus.pending,
          totalChunks: 0,
          indexedChunks: 0,
          lastUpdated: DateTime.now(),
        );
        if (_snapshots[bookId]?.isComplete != true) {
          _snapshots[bookId] = pending;
          _changes.add(pending);
        }
        if (await _databaseService.getIndexStatus(bookId) == null) {
          await _databaseService.saveIndexStatus(pending);
        }
        unawaited(RagBackgroundJobs.schedule());
        await _bookLimiter.acquire();
        _heldSlots.add(bookId);
        if (!await _databaseService.acquireLease(bookId, _leaseOwner)) {
          _releaseSlot(bookId);
          _startingBooks.remove(bookId);
          _progressControllers.remove(bookId);
          await controller.close();
          return;
        }
        _leasedBooks.add(bookId);
        while (interactiveQueries > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final preparing = RagIndexProgress(
          bookId: bookId,
          status: RagIndexStatus.indexing,
          totalChunks: 0,
          indexedChunks: 0,
          lastUpdated: DateTime.now(),
        );
        if (_snapshots[bookId]?.isComplete != true) _changes.add(preparing);
        controller.add(preparing);
        // Start indexing isolate
        debugPrint('[RAG] Starting indexing isolate for $bookId');
        final started = await _startIndexingIsolate(bookId);
        _startingBooks.remove(bookId);
        if (!started) {
          _releaseSlot(bookId);
          _progressControllers.remove(bookId);
          await controller.close();
        }
      } catch (error) {
        _releaseSlot(bookId);
        await _recordFailure(bookId, error);
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

  Future<Isolate> _ensureWorker() async {
    if (_workerIsolate != null) return _workerIsolate!;
    final ready = ReceivePort();
    final errors = ReceivePort();
    errors.listen((message) {
      for (final book in _activeIndexes.keys.toList()) {
        unawaited(_recordFailure(book, StateError('Indexing worker stopped.')));
        _releaseSlot(book);
        final controller = _progressControllers.remove(book);
        controller?.addError(
          StateError('Indexing worker stopped; preparation will resume.'),
        );
        controller?.close();
        _progressPorts.remove(book)?.close();
        _startingBooks.remove(book);
      }
      _activeIndexes.clear();
      _workerIsolate = null;
      _workerRequests = null;
      errors.close();
    });
    _workerIsolate = await Isolate.spawn(
      _indexingWorkerLoop,
      ready.sendPort,
      onError: errors.sendPort,
      onExit: errors.sendPort,
    );
    _workerRequests = await ready.first as SendPort;
    ready.close();
    return _workerIsolate!;
  }

  /// Start indexing in background isolate
  Future<bool> _startIndexingIsolate(String bookId) async {
    // Safety check: verify no isolate exists
    if (_activeIndexes.containsKey(bookId)) {
      debugPrint(
        '[RAG] WARNING: Isolate already exists for $bookId, this should not happen',
      );
      return true;
    }

    final allBooks = await _bookServiceInstance.getAllBooks();
    final book = allBooks.firstWhere(
      (b) => b.id == bookId,
      orElse: () => throw Exception('Book not found: $bookId'),
    );
    if (!await hasLocalBookFile(book)) {
      debugPrint(
        '[RAG] Deferring index for $bookId: EPUB is not on this device',
      );
      return false;
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

    final bookFile = File(book.filePath);

    // Spawn isolate
    debugPrint('[RAG] Spawning indexing isolate for book $bookId');
    final isolate = await _ensureWorker();
    _workerRequests!.send(
      _IndexingWorkerParams(
        bookId: bookId,
        bookFilePath: bookFile.path,
        bookTitle: book.title,
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
        if (message.isComplete || _snapshots[bookId]?.isComplete != true) {
          _snapshots[bookId] = message;
          _changes.add(message);
        }
        _progressControllers[bookId]?.add(message);
      } else if (message is String && message == 'done') {
        _releaseSlot(bookId);
        debugPrint(
          '[RAG] Indexing completed for book $bookId, cleaning up isolate',
        );
        receivePort.close();
        _activeIndexes.remove(bookId);
        _progressPorts.remove(bookId);
        _startingBooks.remove(bookId);
        final finished = _progressControllers.remove(bookId);
        finished?.close();
        if (_rerunBooks.remove(bookId)) {
          Future.microtask(
            () => startIndexing(bookId).listen(
              (_) {},
              onError: (Object e) {
                debugPrint(
                  '[RAG] Reconfigured preparation failed: ${e.runtimeType}',
                );
              },
            ),
          );
        }
      } else if (message is Map && message['error'] != null) {
        _releaseSlot(bookId);
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
    return true;
  }

  /// Stop indexing for a book
  Future<void> stopIndexing(String bookId) async {
    final isolate = _activeIndexes[bookId];
    if (isolate != null) {
      isolate.kill(priority: Isolate.immediate);
      _workerIsolate = null;
      _workerRequests = null;
      _releaseSlot(bookId);
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
    for (final bookId in _activeIndexes.keys.toList()) {
      _activeIndexes[bookId]!.kill(priority: Isolate.immediate);
      _releaseSlot(bookId);
    }
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerRequests = null;
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
  final String bookTitle;
  final SendPort sendPort;
  final RootIsolateToken? rootIsolateToken;

  _IndexingWorkerParams({
    required this.bookId,
    required this.bookFilePath,
    required this.bookTitle,
    required this.sendPort,
    this.rootIsolateToken,
  });
}

/// Worker function for indexing (runs in isolate)
/// Must be top-level or static
void _indexingWorkerLoop(SendPort ready) async {
  final jobs = ReceivePort();
  ready.send(jobs.sendPort);
  await for (final params in jobs) {
    if (params is _IndexingWorkerParams) await _indexingWorker(params);
  }
}

Future<void> _indexingWorker(_IndexingWorkerParams params) async {
  // Initialize background isolate binary messenger for SQLite (if token available)
  if (params.rootIsolateToken != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      params.rootIsolateToken!,
    );
  }

  final databaseService = RagDatabaseService();
  final bookFile = File(params.bookFilePath);
  RagIndexProgress? existingStatus;
  int batchesCompleted = 0; // Track batches for error reporting

  try {
    // Resolve embedding service early so we can derive safe chunk sizes that
    // respect provider limits.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final embeddingService = await RagEmbeddingServiceFactory.create(prefs);

    if (embeddingService == null) {
      final errorProgress = RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.error,
        totalChunks: 0,
        indexedChunks: 0,
        lastUpdated: DateTime.now(),
        errorMessage: await RagEmbeddingServiceFactory.unavailableMessage(
          prefs,
        ),
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
    final effectiveMaxTokens = (configuredMaxTokens.clamp(
      1,
      modelMaxTokens - safetyMargin,
    ));

    final inputStat = await bookFile.stat();
    final canonicalProjection = await const CanonicalBookTextService().fromFile(
      bookFile,
    );
    final chunkingService = RagChunkingService(
      minTokens: configuredMinTokens,
      maxTokens: effectiveMaxTokens,
      overlapTokens: overlapTokens,
      conservativeTokenCount: embeddingService.providerName != 'OpenAI',
    );

    // Chunk the book
    debugPrint(
      '[RAG] Starting chunking for book ${params.bookId} with maxTokens=$effectiveMaxTokens (model limit: $modelMaxTokens)',
    );
    debugPrint(
      '[RAG] EPUB file path: ${bookFile.path}, exists: ${await bookFile.exists()}',
    );
    final chunks = chunkingService.chunkCanonicalBook(
      projection: canonicalProjection,
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
      final chunkTokens = (chunk.text.length / 2).ceil();
      if (chunkTokens > maxTokensPerInput) {
        oversizedChunks++;
        debugPrint(
          '[RAG] WARNING: Chunk ${chunk.chunkId.substring(0, 8)}... exceeds model limit: '
          '$chunkTokens tokens > $maxTokensPerInput (${embeddingService.modelName})',
        );
      }
    }
    if (oversizedChunks > 0) {
      debugPrint(
        '[RAG] Found $oversizedChunks oversized chunks that will be skipped during indexing',
      );
    }

    if (chunks.isEmpty) {
      final errorProgress = RagIndexProgress(
        bookId: params.bookId,
        status: RagIndexStatus.error,
        totalChunks: 0,
        indexedChunks: 0,
        lastUpdated: DateTime.now(),
        errorMessage:
            'No text extracted from EPUB (0 chunks). Check chapter parsing or file content.',
      );
      await databaseService.saveIndexStatus(errorProgress);
      params.sendPort.send(errorProgress);
      params.sendPort.send({'error': errorProgress.errorMessage});
      params.sendPort.send('done');
      return;
    }

    // Compare the complete index contract, not only vector dimensions.
    final totalChunks = chunks.length;
    final configHash = sha256
        .convert(
          utf8.encode(
            'model-token-v4:book-chapter-prefix-v1:$configuredMinTokens:$effectiveMaxTokens:$overlapTokens:'
            '${embeddingService.providerName}:${embeddingService.modelName}:'
            '${embeddingService.embeddingDimensions}',
          ),
        )
        .toString();
    existingStatus = await databaseService.getIndexStatus(params.bookId);
    var existingChunkCount = await databaseService.getChunkCount(params.bookId);
    final compatible =
        existingStatus != null &&
        existingStatus.embeddingProvider == embeddingService.providerName &&
        existingStatus.embeddingModel == embeddingService.modelName &&
        existingStatus.embeddingDimension ==
            embeddingService.embeddingDimensions &&
        existingStatus.contentHash == canonicalProjection.contentHash &&
        existingStatus.extractionVersion ==
            canonicalProjection.extractionVersion &&
        existingStatus.chunkingVersion == RagChunkingService.chunkingVersion &&
        existingStatus.configHash == configHash &&
        existingStatus.indexVersion == RagDatabaseService.indexVersion &&
        existingChunkCount == totalChunks;

    if (existingStatus?.isComplete == true && compatible) {
      final stat = await bookFile.stat();
      await databaseService.saveJob(params.bookId, {
        'fileSize': stat.size,
        'fileModified': stat.modified.millisecondsSinceEpoch,
        'configIdentity':
            '${embeddingService.providerName}:${embeddingService.modelName}:${embeddingService.embeddingDimensions}:${RagChunkingService.chunkingVersion}:${RagDatabaseService.indexVersion}:$configuredMinTokens:$configuredMaxTokens:$overlapTokens',
        'state': 'ready',
        'updated': DateTime.now().toIso8601String(),
      });
      params.sendPort.send(existingStatus);
      params.sendPort.send('done');
      return;
    }

    // A stored credential only proves configuration. Probe the exact endpoint
    // and model before deleting or replacing an existing index.
    await EmbeddingCapabilityService(prefs).ensureAvailable(embeddingService);

    final resumable =
        existingStatus != null &&
        existingStatus.contentHash == canonicalProjection.contentHash &&
        existingStatus.chunkingVersion == RagChunkingService.chunkingVersion &&
        existingStatus.configHash == configHash &&
        existingStatus.indexVersion == RagDatabaseService.indexVersion;
    if (!resumable) await databaseService.clearStagingBook(params.bookId);
    existingChunkCount = await databaseService.getStagedChunkCount(
      params.bookId,
    );
    final chunkingProgress = RagIndexProgress(
      bookId: params.bookId,
      status: RagIndexStatus.indexing,
      totalChunks: totalChunks,
      indexedChunks: existingChunkCount,
      lastUpdated: DateTime.now(),
      embeddingModel: embeddingService.modelName,
      embeddingProvider: embeddingService.providerName,
      embeddingDimension: embeddingService.embeddingDimensions,
      contentHash: canonicalProjection.contentHash,
      extractionVersion: canonicalProjection.extractionVersion,
      chunkingVersion: RagChunkingService.chunkingVersion,
      configHash: configHash,
      indexVersion: RagDatabaseService.indexVersion,
    );
    await databaseService.saveIndexStatus(chunkingProgress);
    params.sendPort.send(chunkingProgress);

    // Filter out already-indexed chunks (idempotency) - batch check for performance
    final chunkRanges = chunks.map((c) => (c.charStart, c.charEnd)).toList();
    debugPrint(
      '[RAG] Checking for existing chunks: ${chunkRanges.length} total chunks',
    );
    debugPrint(
      '[RAG] Sample chunk ranges (first 3): ${chunkRanges.take(3).map((r) => '(${r.$1}-${r.$2})').join(', ')}',
    );
    final existingChunks = await databaseService.chunksExist(
      params.bookId,
      chunkRanges,
      staging: true,
    );
    debugPrint(
      '[RAG] Found ${existingChunks.length} existing chunks out of ${chunkRanges.length} total',
    );
    if (existingChunks.isNotEmpty) {
      debugPrint(
        '[RAG] Sample existing chunks (first 3): ${existingChunks.take(3).map((r) => '(${r.$1}-${r.$2})').join(', ')}',
      );
    }
    // Also check total chunk count in database
    final dbChunkCount = await databaseService.getStagedChunkCount(
      params.bookId,
    );
    debugPrint('[RAG] Total chunks in database for this book: $dbChunkCount');
    final chunksToIndex = chunks.where((chunk) {
      return !existingChunks.contains((chunk.charStart, chunk.charEnd));
    }).toList();
    debugPrint(
      '[RAG] Chunks to index: ${chunksToIndex.length} ($existingChunkCount already indexed)',
    );

    if (chunksToIndex.isEmpty) {
      debugPrint(
        '[RAG] All chunks already indexed for ${params.bookId}, skipping embedding calls',
      );
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

      await databaseService.activateStagedBook(params.bookId);
      final stat = await bookFile.stat();
      await databaseService.saveJob(params.bookId, {
        'fileSize': stat.size,
        'fileModified': stat.modified.millisecondsSinceEpoch,
        'configIdentity':
            '${embeddingService.providerName}:${embeddingService.modelName}:${embeddingService.embeddingDimensions}:${RagChunkingService.chunkingVersion}:${RagDatabaseService.indexVersion}:$configuredMinTokens:$configuredMaxTokens:$overlapTokens',
        'state': 'ready',
        'updated': DateTime.now().toIso8601String(),
      });
      await databaseService.saveIndexStatus(completedProgress);
      params.sendPort.send(completedProgress);
      params.sendPort.send('done');
      return;
    }

    // Index chunks in batches with dynamic batch sizing
    // Use embedding service's actual limits for accurate batch sizing
    final configuredBatchSize = await settingsService.getRagBatchSize();
    final maxConcurrentBatches = await settingsService
        .getRagConcurrentBatches();
    final progressUpdateFrequency = await settingsService
        .getRagProgressUpdateFrequency();

    // Use configured batch size if set, otherwise use provider defaults
    // For mobile, use conservative defaults to avoid memory pressure
    // IMPORTANT: Limit batch size to ensure progress updates are visible
    // Even if chunks fit in one batch, we want multiple batches for progress feedback
    final maxBatchSize = configuredBatchSize > 0
        ? configuredBatchSize.clamp(
            1,
            100,
          ) // Cap at 100 chunks per batch for progress visibility
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
      while (currentIndex < chunksToIndex.length &&
          activeBatches.length < maxConcurrentBatches) {
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
          final errorMsg =
              'Chunk exceeds ${embeddingService.modelName} limit: $chunkTokens tokens > $maxTokensPerInput max';
          debugPrint(
            '[RAG] ERROR: $errorMsg (chunk ${currentIndex + 1}/${chunksToIndex.length})',
          );
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
              while (await databaseService.hasInteractiveReaders()) {
                await Future<void>.delayed(const Duration(milliseconds: 250));
              }
              embeddings = await _generateEmbeddingsWithRetry(
                embeddingService,
                batch
                    .map(
                      (c) => c.chapterTitle?.isNotEmpty == true
                          ? 'Book: ${params.bookTitle}\nChapter: ${c.chapterTitle}\n${c.text}'
                          : 'Book: ${params.bookTitle}\n${c.text}',
                    )
                    .toList(),
              );
            } catch (e) {
              final errorMsg = 'Embedding generation failed: ${e.toString()}';
              debugPrint(
                '[RAG] ERROR: $errorMsg (batch of ${batch.length} chunks)',
              );
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
            debugPrint(
              '[RAG] Saving ${chunksWithEmbeddings.length} chunks to database for book ${params.bookId}',
            );
            await databaseService.saveStagedChunks(chunksWithEmbeddings);
            debugPrint('[RAG] Chunks saved successfully');

            // Get the count BEFORE clearing (this was the bug!)
            final savedCount = chunksWithEmbeddings.length;

            // Clear embeddings from memory to reduce RAM usage
            chunksWithEmbeddings.clear();
            embeddings.clear();

            // Verify chunks were actually saved
            final verifyCount = await databaseService.getStagedChunkCount(
              params.bookId,
            );
            debugPrint(
              '[RAG] Verified chunk count in database after save: $verifyCount',
            );

            final newIndexedCount = await databaseService
                .incrementIndexedChunks(params.bookId, savedCount);
            debugPrint(
              '[RAG] Incremented indexed chunks: $savedCount, new total: $newIndexedCount',
            );

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
            final shouldSendUpdate =
                progressUpdateFrequency == 1 ||
                batchesCompleted % progressUpdateFrequency == 0 ||
                batchesCompleted == 1;

            debugPrint(
              '[RAG] Batch completed: $batchesCompleted, indexedChunks: $newIndexedCount/$totalChunks, shouldSendUpdate: $shouldSendUpdate',
            );

            if (shouldSendUpdate) {
              debugPrint(
                '[RAG] Sending progress update: $newIndexedCount/$totalChunks (${((newIndexedCount / totalChunks) * 100).toStringAsFixed(1)}%)',
              );
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
      debugPrint(
        '[RAG] Waiting for ${activeBatches.length} remaining batches to complete',
      );
      await Future.wait(activeBatches.toList());
      debugPrint('[RAG] All batches completed');
    }

    // Get final count from database for accuracy and ensure progress is up to date
    final finalChunkCount = await databaseService.getStagedChunkCount(
      params.bookId,
    );
    debugPrint(
      '[RAG] Final chunk count in database: $finalChunkCount (expected: $totalChunks)',
    );
    final finalStatus = await databaseService.getIndexStatus(params.bookId);
    indexedCount = finalStatus?.indexedChunks ?? indexedCount;
    debugPrint('[RAG] Final indexed count from status: $indexedCount');
    debugPrint(
      '[RAG] Final stats for ${params.bookId}: indexed=$indexedCount/$totalChunks, batches=$batchesCompleted, dbCount=$finalChunkCount',
    );

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

    if (hadFailures || finalChunkCount != totalChunks) {
      // Build detailed error message
      final errorParts = <String>[];
      if (skippedChunks > 0) {
        errorParts.add(
          '$skippedChunks chunk${skippedChunks > 1 ? 's' : ''} skipped',
        );
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

    final finalInputStat = await bookFile.stat();
    if (finalInputStat.size != inputStat.size ||
        finalInputStat.modified != inputStat.modified) {
      throw StateError('Book changed while indexing; retry preparation.');
    }
    await databaseService.activateStagedBook(params.bookId);
    final stat = await bookFile.stat();
    await databaseService.saveJob(params.bookId, {
      'fileSize': stat.size,
      'fileModified': stat.modified.millisecondsSinceEpoch,
      'configIdentity':
          '${embeddingService.providerName}:${embeddingService.modelName}:${embeddingService.embeddingDimensions}:${RagChunkingService.chunkingVersion}:${RagDatabaseService.indexVersion}:$configuredMinTokens:$configuredMaxTokens:$overlapTokens',
      'state': 'ready',
      'updated': DateTime.now().toIso8601String(),
    });
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
      embeddingModel:
          existingStatus?.embeddingModel ?? currentStatus?.embeddingModel,
      embeddingDimension:
          existingStatus?.embeddingDimension ??
          currentStatus?.embeddingDimension,
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
        debugPrint(
          '[RAG] Rate limit hit. API suggests retry after ${e.retryAfterSeconds}s (attempt $attempt/$maxRetries)',
        );
      } else {
        // Exponential backoff: 2s, 4s, 8s, 16s, 32s
        debugPrint(
          '[RAG] Rate limit hit. Using exponential backoff: ${delay.inSeconds}s (attempt $attempt/$maxRetries)',
        );
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
      debugPrint(
        '[RAG] Network error: ${e.message} (attempt $attempt/$maxRetries)',
      );

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
  int tokenize(String text) {
    // Simple token estimation: ~4 characters per token (conservative)
    // For more accuracy, we could use the actual tokenizer, but this is faster
    return (text.length / 4).ceil();
  }

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
