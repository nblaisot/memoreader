enum ReadingProgressAnchorOrigin {
  legacy,
  userNavigation;

  static ReadingProgressAnchorOrigin fromJson(Object? value) {
    return value == 'userNavigation'
        ? ReadingProgressAnchorOrigin.userNavigation
        : ReadingProgressAnchorOrigin.legacy;
  }
}

/// Persisted reading progress anchored by character offset and percentage.
class ReadingProgress {
  static const int currentSchemaVersion = 2;

  final String bookId;
  final DateTime lastRead;
  final int? totalPages; // legacy value, may be null
  final String? contentCfi;
  final double? progress;
  final int?
  currentCharacterIndex; // Exact character position for pagination engine
  final int?
  lastVisibleCharacterIndex; // Last character that was visible on screen
  final int?
  currentPageIndex; // Current page index (for WebView reader - more reliable than calculating from percentage)
  // Layout parameters for fast startup and foldable phone support
  final double? maxWidth;
  final double? maxHeight;
  final double? fontSize;
  final double? horizontalPadding;
  final double? verticalPadding;
  final String? layoutKey; // Computed layout key for quick comparison
  final int schemaVersion;
  final int? totalCharacters;
  final int? contentVersion;
  final ReadingProgressAnchorOrigin anchorOrigin;

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
    this.schemaVersion = currentSchemaVersion,
    this.totalCharacters,
    this.contentVersion,
    this.anchorOrigin = ReadingProgressAnchorOrigin.legacy,
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
      'schemaVersion': schemaVersion,
      'totalCharacters': totalCharacters,
      'contentVersion': contentVersion,
      'anchorOrigin': anchorOrigin.name,
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
      schemaVersion: json['schemaVersion'] as int? ?? 1,
      totalCharacters: json['totalCharacters'] as int?,
      contentVersion: json['contentVersion'] as int?,
      anchorOrigin: ReadingProgressAnchorOrigin.fromJson(json['anchorOrigin']),
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
    int? schemaVersion,
    int? totalCharacters,
    int? contentVersion,
    ReadingProgressAnchorOrigin? anchorOrigin,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      lastRead: lastRead ?? this.lastRead,
      totalPages: totalPages ?? this.totalPages,
      contentCfi: contentCfi ?? this.contentCfi,
      progress: progress ?? this.progress,
      currentCharacterIndex:
          currentCharacterIndex ?? this.currentCharacterIndex,
      lastVisibleCharacterIndex:
          lastVisibleCharacterIndex ?? this.lastVisibleCharacterIndex,
      currentPageIndex: currentPageIndex ?? this.currentPageIndex,
      maxWidth: maxWidth ?? this.maxWidth,
      maxHeight: maxHeight ?? this.maxHeight,
      fontSize: fontSize ?? this.fontSize,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      verticalPadding: verticalPadding ?? this.verticalPadding,
      layoutKey: layoutKey ?? this.layoutKey,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      totalCharacters: totalCharacters ?? this.totalCharacters,
      contentVersion: contentVersion ?? this.contentVersion,
      anchorOrigin: anchorOrigin ?? this.anchorOrigin,
    );
  }

  bool get isAtBeginning =>
      (currentCharacterIndex ?? 0) <= 0 && (currentPageIndex ?? 0) <= 1;
}
