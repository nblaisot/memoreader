class BookSummaryChunk {
  final String bookId;
  final int chunkIndex;
  final ChunkType chunkType;
  final String summaryText;
  final int? tokenCount;
  final DateTime createdAt;

  BookSummaryChunk({
    required this.bookId,
    required this.chunkIndex,
    required this.chunkType,
    required this.summaryText,
    this.tokenCount,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'bookId': bookId,
      'chunkIndex': chunkIndex,
      'chunkType': chunkType.name,
      'summaryText': summaryText,
      'tokenCount': tokenCount,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory BookSummaryChunk.fromJson(Map<String, dynamic> json) {
    return BookSummaryChunk(
      bookId: json['bookId'] as String,
      chunkIndex: json['chunkIndex'] as int,
      chunkType: ChunkType.values.firstWhere(
        (e) => e.name == json['chunkType'],
        orElse: () => ChunkType.chapter,
      ),
      summaryText: json['summaryText'] as String,
      tokenCount: json['tokenCount'] as int?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

enum ChunkType {
  chapter,
  fixedBlock,
}
