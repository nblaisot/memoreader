class Book {
  final String id;
  final String title;
  final String author;
  final String? coverImagePath;
  final String filePath;
  final DateTime dateAdded;

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.coverImagePath,
    required this.filePath,
    required this.dateAdded,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'coverImagePath': coverImagePath,
      'filePath': filePath,
      'dateAdded': dateAdded.toIso8601String(),
    };
  }

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      coverImagePath: json['coverImagePath'] as String?,
      filePath: json['filePath'] as String,
      dateAdded: DateTime.parse(json['dateAdded'] as String),
    );
  }
}

