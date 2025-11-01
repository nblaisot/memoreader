class ReadingProgress {
  final String bookId;
  final int currentChapterIndex;
  final int currentPageInChapter;
  final DateTime lastRead;

  ReadingProgress({
    required this.bookId,
    required this.currentChapterIndex,
    required this.currentPageInChapter,
    required this.lastRead,
  });

  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'currentChapterIndex': currentChapterIndex,
      'currentPageInChapter': currentPageInChapter,
      'lastRead': lastRead.toIso8601String(),
    };
  }

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    return ReadingProgress(
      bookId: json['bookId'] as String,
      currentChapterIndex: json['currentChapterIndex'] as int,
      currentPageInChapter: json['currentPageInChapter'] as int,
      lastRead: DateTime.parse(json['lastRead'] as String),
    );
  }

  ReadingProgress copyWith({
    String? bookId,
    int? currentChapterIndex,
    int? currentPageInChapter,
    DateTime? lastRead,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
      currentPageInChapter: currentPageInChapter ?? this.currentPageInChapter,
      lastRead: lastRead ?? this.lastRead,
    );
  }
}

