import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/services/book_service.dart';
import 'package:memoreader/services/rag_indexing_service.dart';

class _BookServiceWithOneBook extends BookService {
  _BookServiceWithOneBook(this.book);

  final Book book;

  @override
  Future<List<Book>> getAllBooks() async => [book];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remote-only books are deferred without starting an index', () async {
    final directory = await Directory.systemTemp.createTemp('rag-local-book-');
    try {
      final book = Book(
        id: 'remote-only-book',
        title: 'Remote book',
        author: 'Author',
        filePath: '${directory.path}/not-downloaded.epub',
        dateAdded: DateTime.now(),
      );
      expect(await RagIndexingService.hasLocalBookFile(book), isFalse);

      final indexer = RagIndexingService(
        bookService: _BookServiceWithOneBook(book),
      );
      expect(await indexer.startIndexing(book.id).toList(), isEmpty);
      expect(indexer.isIndexing(book.id), isFalse);

      final file = File(book.filePath);
      await file.writeAsBytes([1, 2, 3]);
      expect(await RagIndexingService.hasLocalBookFile(book), isTrue);
      await file.writeAsBytes([]);
      expect(await RagIndexingService.hasLocalBookFile(book), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
