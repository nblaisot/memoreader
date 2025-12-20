class Book {
  final String id;
  final String title;
  final String author;
  final String? coverImagePath;  // This will be the full path (constructed at load time)
  final String filePath;  // This will be the full path (constructed at load time)
  final DateTime dateAdded;
  final bool isValid;

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.coverImagePath,
    required this.filePath,
    required this.dateAdded,
    this.isValid = true,
  });

  /// Extracts just the filename from a full path
  static String _extractFileName(String path) {
    if (path.isEmpty) return '';
    return path.split('/').last;
  }

  /// Converts to JSON - stores only filenames, not full paths
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'coverFileName': coverImagePath != null ? _extractFileName(coverImagePath!) : null,
      'fileName': _extractFileName(filePath),
      'dateAdded': dateAdded.toIso8601String(),
      'isValid': isValid,
    };
  }

  /// Creates Book from JSON - requires booksDir and coversDir to construct full paths
  factory Book.fromJson(Map<String, dynamic> json, {
    required String booksDirectory,
    required String coversDirectory,
  }) {
    final fileName = json['fileName'] as String? ?? json['filePath'] as String;  // Support old format
    final coverFileName = json['coverFileName'] as String?;
    
    // Construct full paths
    final fullPath = fileName.contains('/') ? fileName : '$booksDirectory/$fileName';
    final fullCoverPath = coverFileName != null 
        ? (coverFileName.contains('/') ? coverFileName : '$coversDirectory/$coverFileName')
        : null;

    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      coverImagePath: fullCoverPath,
      filePath: fullPath,
      dateAdded: DateTime.parse(json['dateAdded'] as String),
      isValid: json['isValid'] as bool? ?? true,
    );
  }
}

