class ReadingProgress {
  final String bookId;
  final int? currentChapterIndex;
  final int? currentPageInChapter;
  final DateTime lastRead;
  final int? totalPages; // legacy value, may be null
  final String? contentCfi;
  final double? progress;
  final int? currentWordIndex; // First word of current page for lazy pagination
  final int? currentCharacterIndex; // Exact character position for pagination engine

  ReadingProgress({
    required this.bookId,
    required this.lastRead,
    this.currentChapterIndex,
    this.currentPageInChapter,
    this.totalPages,
    this.contentCfi,
    this.progress,
    this.currentWordIndex,
    this.currentCharacterIndex,
  });

  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'currentChapterIndex': currentChapterIndex,
      'currentPageInChapter': currentPageInChapter,
      'lastRead': lastRead.toIso8601String(),
      'totalPages': totalPages,
      'contentCfi': contentCfi,
      'progress': progress,
      'currentWordIndex': currentWordIndex,
      'currentCharacterIndex': currentCharacterIndex,
    };
  }

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    return ReadingProgress(
      bookId: json['bookId'] as String,
      currentChapterIndex: json['currentChapterIndex'] as int?,
      currentPageInChapter: json['currentPageInChapter'] as int?,
      lastRead: DateTime.parse(json['lastRead'] as String),
      totalPages: json['totalPages'] as int?,
      contentCfi: json['contentCfi'] as String?,
      progress: (json['progress'] as num?)?.toDouble(),
      currentWordIndex: json['currentWordIndex'] as int?,
      currentCharacterIndex: json['currentCharacterIndex'] as int?,
    );
  }

  ReadingProgress copyWith({
    String? bookId,
    int? currentChapterIndex,
    int? currentPageInChapter,
    DateTime? lastRead,
    int? totalPages,
    String? contentCfi,
    double? progress,
    int? currentWordIndex,
    int? currentCharacterIndex,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
      currentPageInChapter: currentPageInChapter ?? this.currentPageInChapter,
      lastRead: lastRead ?? this.lastRead,
      totalPages: totalPages ?? this.totalPages,
      contentCfi: contentCfi ?? this.contentCfi,
      progress: progress ?? this.progress,
      currentWordIndex: currentWordIndex ?? this.currentWordIndex,
      currentCharacterIndex: currentCharacterIndex ?? this.currentCharacterIndex,
    );
  }
}

