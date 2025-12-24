/// A saved translation from the reader
class SavedTranslation {
  final int? id;
  final String bookId;
  final String original;
  final String? pronunciation;
  final String translation;
  final DateTime createdAt;

  SavedTranslation({
    this.id,
    required this.bookId,
    required this.original,
    this.pronunciation,
    required this.translation,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'bookId': bookId,
      'original': original,
      'pronunciation': pronunciation,
      'translation': translation,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory SavedTranslation.fromJson(Map<String, dynamic> json) {
    return SavedTranslation(
      id: json['id'] as int?,
      bookId: json['bookId'] as String,
      original: json['original'] as String,
      pronunciation: json['pronunciation'] as String?,
      translation: json['translation'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  SavedTranslation copyWith({
    int? id,
    String? bookId,
    String? original,
    String? pronunciation,
    String? translation,
    DateTime? createdAt,
  }) {
    return SavedTranslation(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      original: original ?? this.original,
      pronunciation: pronunciation ?? this.pronunciation,
      translation: translation ?? this.translation,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

