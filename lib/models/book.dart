/// Book model representing a book in the library
/// 
/// Supports multiple formats: EPUB and TXT
class Book {
  final String id;
  final String title;
  final String author;
  final String? coverImagePath;
  final String filePath;
  final DateTime dateAdded;
  final String format; // 'epub' or 'txt'

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.coverImagePath,
    required this.filePath,
    required this.dateAdded,
    required this.format,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'coverImagePath': coverImagePath,
      'filePath': filePath,
      'dateAdded': dateAdded.toIso8601String(),
      'format': format,
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
      // Default to 'epub' for backward compatibility with existing books
      format: json['format'] as String? ?? 'epub',
    );
  }
}

