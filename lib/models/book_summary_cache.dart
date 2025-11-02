class BookSummaryCache {
  final String bookId;
  final int lastProcessedChunkIndex;
  final String cumulativeSummary;
  final DateTime lastUpdated;
  final int? lastSummaryViewChunkIndex; // Track where user was when they last viewed summary
  final int? lastReadingStopChunkIndex; // Track where user stopped reading last time
  final DateTime? lastReadingStopTimestamp; // Track when user stopped reading last time
  final int? previousReadingStopChunkIndex; // Track where user stopped reading before that (for "since last time")
  final DateTime? previousReadingStopTimestamp; // Track when user stopped reading before that
  final String? summarySinceLastTime; // Cached "since last time" summary
  final int? summarySinceLastTimeChunkIndex; // Chunk index when "since last time" summary was generated
  final String? charactersSummary; // Cached characters summary
  final int? charactersSummaryChunkIndex; // Chunk index when characters summary was generated
  final String? importantWords; // Cached important words table

  BookSummaryCache({
    required this.bookId,
    required this.lastProcessedChunkIndex,
    required this.cumulativeSummary,
    required this.lastUpdated,
    this.lastSummaryViewChunkIndex,
    this.lastReadingStopChunkIndex,
    this.lastReadingStopTimestamp,
    this.previousReadingStopChunkIndex,
    this.previousReadingStopTimestamp,
    this.summarySinceLastTime,
    this.summarySinceLastTimeChunkIndex,
    this.charactersSummary,
    this.charactersSummaryChunkIndex,
    this.importantWords,
  });

  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'lastProcessedChunkIndex': lastProcessedChunkIndex,
      'cumulativeSummary': cumulativeSummary,
      'lastUpdated': lastUpdated.toIso8601String(),
      'lastSummaryViewChunkIndex': lastSummaryViewChunkIndex,
      'lastReadingStopChunkIndex': lastReadingStopChunkIndex,
      'lastReadingStopTimestamp': lastReadingStopTimestamp?.toIso8601String(),
      'previousReadingStopChunkIndex': previousReadingStopChunkIndex,
      'previousReadingStopTimestamp': previousReadingStopTimestamp?.toIso8601String(),
      'summarySinceLastTime': summarySinceLastTime,
      'summarySinceLastTimeChunkIndex': summarySinceLastTimeChunkIndex,
      'charactersSummary': charactersSummary,
      'charactersSummaryChunkIndex': charactersSummaryChunkIndex,
      'importantWords': importantWords,
    };
  }

  factory BookSummaryCache.fromJson(Map<String, dynamic> json) {
    return BookSummaryCache(
      bookId: json['bookId'] as String,
      lastProcessedChunkIndex: json['lastProcessedChunkIndex'] as int,
      cumulativeSummary: json['cumulativeSummary'] as String,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      lastSummaryViewChunkIndex: json['lastSummaryViewChunkIndex'] as int?,
      lastReadingStopChunkIndex: json['lastReadingStopChunkIndex'] as int?,
      lastReadingStopTimestamp: json['lastReadingStopTimestamp'] != null
          ? DateTime.parse(json['lastReadingStopTimestamp'] as String)
          : null,
      previousReadingStopChunkIndex: json['previousReadingStopChunkIndex'] as int?,
      previousReadingStopTimestamp: json['previousReadingStopTimestamp'] != null
          ? DateTime.parse(json['previousReadingStopTimestamp'] as String)
          : null,
      summarySinceLastTime: json['summarySinceLastTime'] as String?,
      summarySinceLastTimeChunkIndex: json['summarySinceLastTimeChunkIndex'] as int?,
      charactersSummary: json['charactersSummary'] as String?,
      charactersSummaryChunkIndex: json['charactersSummaryChunkIndex'] as int?,
      importantWords: json['importantWords'] as String?,
    );
  }

  BookSummaryCache copyWith({
    String? bookId,
    int? lastProcessedChunkIndex,
    String? cumulativeSummary,
    DateTime? lastUpdated,
    int? lastSummaryViewChunkIndex,
    int? lastReadingStopChunkIndex,
    DateTime? lastReadingStopTimestamp,
    int? previousReadingStopChunkIndex,
    DateTime? previousReadingStopTimestamp,
    String? summarySinceLastTime,
    int? summarySinceLastTimeChunkIndex,
    String? charactersSummary,
    int? charactersSummaryChunkIndex,
    String? importantWords,
  }) {
    return BookSummaryCache(
      bookId: bookId ?? this.bookId,
      lastProcessedChunkIndex:
          lastProcessedChunkIndex ?? this.lastProcessedChunkIndex,
      cumulativeSummary: cumulativeSummary ?? this.cumulativeSummary,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      lastSummaryViewChunkIndex: lastSummaryViewChunkIndex ?? this.lastSummaryViewChunkIndex,
      lastReadingStopChunkIndex: lastReadingStopChunkIndex ?? this.lastReadingStopChunkIndex,
      lastReadingStopTimestamp: lastReadingStopTimestamp ?? this.lastReadingStopTimestamp,
      previousReadingStopChunkIndex: previousReadingStopChunkIndex ?? this.previousReadingStopChunkIndex,
      previousReadingStopTimestamp: previousReadingStopTimestamp ?? this.previousReadingStopTimestamp,
      summarySinceLastTime: summarySinceLastTime ?? this.summarySinceLastTime,
      summarySinceLastTimeChunkIndex: summarySinceLastTimeChunkIndex ?? this.summarySinceLastTimeChunkIndex,
      charactersSummary: charactersSummary ?? this.charactersSummary,
      charactersSummaryChunkIndex: charactersSummaryChunkIndex ?? this.charactersSummaryChunkIndex,
      importantWords: importantWords ?? this.importantWords,
    );
  }
}
