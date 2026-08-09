/// Status of RAG indexing for a book
enum RagIndexStatus {
  pending, // Indexing not started
  indexing, // Currently indexing
  completed, // Indexing finished successfully
  error, // Indexing failed
}

/// Represents the progress of indexing a book for RAG
class RagIndexProgress {
  final String bookId;
  final RagIndexStatus status;
  final int totalChunks;
  final int indexedChunks;
  final DateTime lastUpdated;
  final String? errorMessage;
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
