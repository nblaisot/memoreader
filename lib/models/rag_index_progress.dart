enum RagReadiness { unknown, preparing, ready, failed }

RagReadiness readinessOf(RagIndexProgress? progress) {
  if (progress == null) return RagReadiness.unknown;
  if (progress.isComplete) return RagReadiness.ready;
  if (progress.hasError) return RagReadiness.failed;
  return RagReadiness.preparing;
}

/// Status of RAG indexing for a book
enum RagIndexStatus {
  pending, // Indexing not started
  indexing, // Currently indexing
  completed, // Indexing finished successfully
  error, // Indexing failed
  waiting, // Durable provider cooldown, not an indexing failure
}

/// Represents the progress of indexing a book for RAG
class RagIndexProgress {
  final String bookId;
  final RagIndexStatus status;
  final int totalChunks;
  final int indexedChunks;
  final DateTime lastUpdated;
  final String? errorMessage;
  final DateTime? nextRetryAt;
  final String? waitReason;
  final String?
  embeddingModel; // 'text-embedding-3-small', 'mistral-embed', etc.
  final String? embeddingProvider;
  final int? embeddingDimension; // 1536, 1024, etc.
  final String? contentHash;
  final int? extractionVersion;
  final int? chunkingVersion;
  final String? configHash;
  final int? indexVersion;
  final int? skippedChunks; // Chunks skipped due to size limits or errors
  final int?
  apiCalls; // Number of embedding API calls (batches) used during indexing

  RagIndexProgress({
    required this.bookId,
    required this.status,
    required this.totalChunks,
    required this.indexedChunks,
    required this.lastUpdated,
    this.errorMessage,
    this.nextRetryAt,
    this.waitReason,
    this.embeddingModel,
    this.embeddingProvider,
    this.embeddingDimension,
    this.contentHash,
    this.extractionVersion,
    this.chunkingVersion,
    this.configHash,
    this.indexVersion,
    this.skippedChunks,
    this.apiCalls,
  });

  /// Get progress percentage (0-100)
  double get progressPercentage {
    if (totalChunks == 0) return 0.0;
    return (indexedChunks / totalChunks) * 100.0;
  }

  /// Check if indexing is complete
  bool get isComplete => status == RagIndexStatus.completed;

  /// Check if indexing is in progress
  bool get isIndexing => status == RagIndexStatus.indexing;
  bool get isWaiting => status == RagIndexStatus.waiting;

  /// Check if indexing has error
  bool get hasError => status == RagIndexStatus.error;

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'status': status.name,
      'totalChunks': totalChunks,
      'indexedChunks': indexedChunks,
      'lastUpdated': lastUpdated.toIso8601String(),
      'errorMessage': errorMessage,
      'nextRetryAt': nextRetryAt?.millisecondsSinceEpoch,
      'waitReason': waitReason,
      'embeddingModel': embeddingModel,
      'embeddingProvider': embeddingProvider,
      'embeddingDimension': embeddingDimension,
      'contentHash': contentHash,
      'extractionVersion': extractionVersion,
      'chunkingVersion': chunkingVersion,
      'configHash': configHash,
      'indexVersion': indexVersion,
      'skippedChunks': skippedChunks,
      'apiCalls': apiCalls,
    };
  }

  /// Deserialize from JSON
  factory RagIndexProgress.fromJson(Map<String, dynamic> json) {
    return RagIndexProgress(
      bookId: json['bookId'] as String,
      status: RagIndexStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => RagIndexStatus.pending,
      ),
      totalChunks: json['totalChunks'] as int,
      indexedChunks: json['indexedChunks'] as int,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      errorMessage: json['errorMessage'] as String?,
      nextRetryAt: json['nextRetryAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(json['nextRetryAt'] as int)
          : null,
      waitReason: json['waitReason'] as String?,
      embeddingModel: json['embeddingModel'] as String?,
      embeddingProvider: json['embeddingProvider'] as String?,
      embeddingDimension: json['embeddingDimension'] as int?,
      contentHash: json['contentHash'] as String?,
      extractionVersion: json['extractionVersion'] as int?,
      chunkingVersion: json['chunkingVersion'] as int?,
      configHash: json['configHash'] as String?,
      indexVersion: json['indexVersion'] as int?,
      skippedChunks: json['skippedChunks'] as int?,
      apiCalls: json['apiCalls'] as int?,
    );
  }

  /// Create a copy with modified fields
  RagIndexProgress copyWith({
    String? bookId,
    RagIndexStatus? status,
    int? totalChunks,
    int? indexedChunks,
    DateTime? lastUpdated,
    String? errorMessage,
    DateTime? nextRetryAt,
    String? waitReason,
    String? embeddingModel,
    String? embeddingProvider,
    int? embeddingDimension,
    String? contentHash,
    int? extractionVersion,
    int? chunkingVersion,
    String? configHash,
    int? indexVersion,
    int? skippedChunks,
    int? apiCalls,
  }) {
    return RagIndexProgress(
      bookId: bookId ?? this.bookId,
      status: status ?? this.status,
      totalChunks: totalChunks ?? this.totalChunks,
      indexedChunks: indexedChunks ?? this.indexedChunks,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      errorMessage: errorMessage ?? this.errorMessage,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      waitReason: waitReason ?? this.waitReason,
      embeddingModel: embeddingModel ?? this.embeddingModel,
      embeddingProvider: embeddingProvider ?? this.embeddingProvider,
      embeddingDimension: embeddingDimension ?? this.embeddingDimension,
      contentHash: contentHash ?? this.contentHash,
      extractionVersion: extractionVersion ?? this.extractionVersion,
      chunkingVersion: chunkingVersion ?? this.chunkingVersion,
      configHash: configHash ?? this.configHash,
      indexVersion: indexVersion ?? this.indexVersion,
      skippedChunks: skippedChunks ?? this.skippedChunks,
      apiCalls: apiCalls ?? this.apiCalls,
    );
  }
}

/// Provider cooldowns and transport recovery are different user-visible waits.
String embeddingWaitLabel(
  String? reason, {
  required bool french,
  required int remainingSeconds,
}) {
  final label = switch (reason) {
    'network' =>
      french
          ? 'Préparation en pause — nouvelle tentative de connexion'
          : 'Preparation paused — retrying connection',
    'timeout' =>
      french
          ? 'Préparation en pause — délai du fournisseur dépassé'
          : 'Preparation paused — provider response timed out',
    'provider_busy' =>
      french
          ? 'Préparation en pause — fournisseur occupé'
          : 'Preparation paused — provider busy',
    'interactive_priority' || 'active_request' =>
      french
          ? 'Préparation en pause — requête en cours'
          : 'Preparation paused — another request is active',
    'retry_budget' =>
      french
          ? 'Préparation en pause — reprise programmée'
          : 'Preparation paused — retry scheduled',
    _ =>
      french
          ? 'Préparation en pause — limite du fournisseur'
          : 'Preparation paused — waiting for provider limits',
  };
  return '$label${remainingSeconds > 0 ? ' · $remainingSeconds s' : ''}';
}
