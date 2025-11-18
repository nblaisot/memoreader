/// Persisted reading progress based solely on exact character offsets.
class ReadingProgress {
  final String bookId;
  final DateTime lastRead;
  final int? totalPages; // legacy value, may be null
  final String? contentCfi;
  final double? progress;
  final int? currentCharacterIndex; // Exact character position for pagination engine

  ReadingProgress({
    required this.bookId,
    required this.lastRead,
    this.totalPages,
    this.contentCfi,
    this.progress,
    this.currentCharacterIndex,
  });

  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'lastRead': lastRead.toIso8601String(),
      'totalPages': totalPages,
      'contentCfi': contentCfi,
      'progress': progress,
      'currentCharacterIndex': currentCharacterIndex,
    };
  }

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    return ReadingProgress(
      bookId: json['bookId'] as String,
      lastRead: DateTime.parse(json['lastRead'] as String),
      totalPages: json['totalPages'] as int?,
      contentCfi: json['contentCfi'] as String?,
      progress: (json['progress'] as num?)?.toDouble(),
      currentCharacterIndex: json['currentCharacterIndex'] as int?,
    );
  }

  ReadingProgress copyWith({
    String? bookId,
    DateTime? lastRead,
    int? totalPages,
    String? contentCfi,
    double? progress,
    int? currentCharacterIndex,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      lastRead: lastRead ?? this.lastRead,
      totalPages: totalPages ?? this.totalPages,
      contentCfi: contentCfi ?? this.contentCfi,
      progress: progress ?? this.progress,
      currentCharacterIndex: currentCharacterIndex ?? this.currentCharacterIndex,
    );
  }
}

