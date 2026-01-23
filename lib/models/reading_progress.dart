/// Persisted reading progress based solely on exact character offsets.
class ReadingProgress {
  final String bookId;
  final DateTime lastRead;
  final int? totalPages; // legacy value, may be null
  final String? contentCfi;
  final double? progress;
  final int? currentCharacterIndex; // Exact character position for pagination engine
  final int? lastVisibleCharacterIndex; // Last character that was visible on screen
  final int? currentPageIndex; // Current page index (for WebView reader - more reliable than calculating from percentage)
  // Layout parameters for fast startup and foldable phone support
  final double? maxWidth;
  final double? maxHeight;
  final double? fontSize;
  final double? horizontalPadding;
  final double? verticalPadding;
  final String? layoutKey; // Computed layout key for quick comparison

  ReadingProgress({
    required this.bookId,
    required this.lastRead,
    this.totalPages,
    this.contentCfi,
    this.progress,
    this.currentCharacterIndex,
    this.lastVisibleCharacterIndex,
    this.currentPageIndex,
    this.maxWidth,
    this.maxHeight,
    this.fontSize,
    this.horizontalPadding,
    this.verticalPadding,
    this.layoutKey,
  });

  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'lastRead': lastRead.toIso8601String(),
      'totalPages': totalPages,
      'contentCfi': contentCfi,
      'progress': progress,
      'currentCharacterIndex': currentCharacterIndex,
      'lastVisibleCharacterIndex': lastVisibleCharacterIndex,
      'currentPageIndex': currentPageIndex,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'fontSize': fontSize,
      'horizontalPadding': horizontalPadding,
      'verticalPadding': verticalPadding,
      'layoutKey': layoutKey,
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
      lastVisibleCharacterIndex: json['lastVisibleCharacterIndex'] as int?,
      currentPageIndex: json['currentPageIndex'] as int?,
      maxWidth: (json['maxWidth'] as num?)?.toDouble(),
      maxHeight: (json['maxHeight'] as num?)?.toDouble(),
      fontSize: (json['fontSize'] as num?)?.toDouble(),
      horizontalPadding: (json['horizontalPadding'] as num?)?.toDouble(),
      verticalPadding: (json['verticalPadding'] as num?)?.toDouble(),
      layoutKey: json['layoutKey'] as String?,
    );
  }

  ReadingProgress copyWith({
    String? bookId,
    DateTime? lastRead,
    int? totalPages,
    String? contentCfi,
    double? progress,
    int? currentCharacterIndex,
    int? lastVisibleCharacterIndex,
    int? currentPageIndex,
    double? maxWidth,
    double? maxHeight,
    double? fontSize,
    double? horizontalPadding,
    double? verticalPadding,
    String? layoutKey,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      lastRead: lastRead ?? this.lastRead,
      totalPages: totalPages ?? this.totalPages,
      contentCfi: contentCfi ?? this.contentCfi,
      progress: progress ?? this.progress,
      currentCharacterIndex: currentCharacterIndex ?? this.currentCharacterIndex,
      lastVisibleCharacterIndex:
          lastVisibleCharacterIndex ?? this.lastVisibleCharacterIndex,
      currentPageIndex: currentPageIndex ?? this.currentPageIndex,
      maxWidth: maxWidth ?? this.maxWidth,
      maxHeight: maxHeight ?? this.maxHeight,
      fontSize: fontSize ?? this.fontSize,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      verticalPadding: verticalPadding ?? this.verticalPadding,
      layoutKey: layoutKey ?? this.layoutKey,
    );
  }
}

