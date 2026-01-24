import 'dart:typed_data';

/// Represents a chunk of text from a book with its embedding for RAG.
class RagChunk {
  final String chunkId;
  final String bookId;
  final String text;
  final Float32List embedding; // FLOAT32 array
  final int embeddingDimension; // Dimension of embedding (1536, 1024, etc.)
  final int? chapterIndex;
  final int charStart; // Absolute character position in book
  final int charEnd; // Absolute character position in book
  final int tokenStart; // Token index for overlap tracking
  final int tokenEnd; // Token index for overlap tracking
  final DateTime createdAt;

  RagChunk({
    required this.chunkId,
    required this.bookId,
    required this.text,
    required this.embedding,
    required this.embeddingDimension,
    this.chapterIndex,
    required this.charStart,
    required this.charEnd,
    required this.tokenStart,
    required this.tokenEnd,
    required this.createdAt,
  });

  /// Convert Float32List to Uint8List for BLOB storage
  Uint8List embeddingToBlob() {
    return Uint8List.view(embedding.buffer);
  }

  /// Create Float32List from Uint8List (BLOB)
  static Float32List embeddingFromBlob(Uint8List blob) {
    // Each float is 4 bytes, so divide blob length by 4 to get number of floats
    final floatCount = blob.length ~/ 4;
    
    // Create a ByteData view to properly read the bytes as floats
    final byteData = ByteData.sublistView(blob);
    final floats = Float32List(floatCount);
    
    for (int i = 0; i < floatCount; i++) {
      floats[i] = byteData.getFloat32(i * 4, Endian.host);
    }
    
    return floats;
  }

  /// Serialize to JSON (for non-embedding fields only)
  Map<String, dynamic> toJson() {
    return {
      'chunkId': chunkId,
      'bookId': bookId,
      'text': text,
      'embeddingDimension': embeddingDimension,
      'chapterIndex': chapterIndex,
      'charStart': charStart,
      'charEnd': charEnd,
      'tokenStart': tokenStart,
      'tokenEnd': tokenEnd,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// Deserialize from JSON + BLOB
  factory RagChunk.fromJson(Map<String, dynamic> json, Uint8List embeddingBlob) {
    return RagChunk(
      chunkId: json['chunkId'] as String,
      bookId: json['bookId'] as String,
      text: json['text'] as String,
      embedding: embeddingFromBlob(embeddingBlob),
      embeddingDimension: json['embeddingDimension'] as int,
      chapterIndex: json['chapterIndex'] as int?,
      charStart: json['charStart'] as int,
      charEnd: json['charEnd'] as int,
      tokenStart: json['tokenStart'] as int,
      tokenEnd: json['tokenEnd'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// Create a copy with modified fields
  RagChunk copyWith({
    String? chunkId,
    String? bookId,
    String? text,
    Float32List? embedding,
    int? embeddingDimension,
    int? chapterIndex,
    int? charStart,
    int? charEnd,
    int? tokenStart,
    int? tokenEnd,
    DateTime? createdAt,
  }) {
    return RagChunk(
      chunkId: chunkId ?? this.chunkId,
      bookId: bookId ?? this.bookId,
      text: text ?? this.text,
      embedding: embedding ?? this.embedding,
      embeddingDimension: embeddingDimension ?? this.embeddingDimension,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      charStart: charStart ?? this.charStart,
      charEnd: charEnd ?? this.charEnd,
      tokenStart: tokenStart ?? this.tokenStart,
      tokenEnd: tokenEnd ?? this.tokenEnd,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
