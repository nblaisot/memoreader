import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/models/reading_progress.dart';
import 'package:memoreader/services/book_service.dart';
import 'package:memoreader/services/rag_indexing_service.dart';
import 'package:memoreader/services/txt_to_epub_converter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathProviderPlatform savedPathProvider;
  final service = BookService();

  setUp(() async {
    savedPathProvider = PathProviderPlatform.instance;
    tempRoot = Directory.systemTemp.createTempSync('memoreader_book_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    PathProviderPlatform.instance = savedPathProvider;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('BookService copyEpubFile', () {
    test('throws when source file is missing', () async {
      final missing = File('${tempRoot.path}/nope.epub');
      expect(
        () => service.copyEpubFile(missing),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('does not exist'),
        )),
      );
    });

    test('copies EPUB into books directory with bookId file name', () async {
      final src = File('${tempRoot.path}/source.epub');
      await src.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);

      final destPath = await service.copyEpubFile(src, bookId: 'abc123');
      expect(await File(destPath).exists(), isTrue);
      expect(destPath, endsWith('${Platform.pathSeparator}abc123.epub'));

      final booksDir = await service.getBooksDirectory();
      expect(destPath, '$booksDir${Platform.pathSeparator}abc123.epub');
    });
  });

  group('BookService importEpub', () {
    test('throws when file does not exist', () async {
      final f = File('${tempRoot.path}/missing.epub');
      expect(
        () => service.importEpub(f),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('does not exist'),
        )),
      );
    });
  });

  group('BookService reading progress', () {
    test('saveReadingProgress round-trips via getReadingProgress', () async {
      final progress = ReadingProgress(
        bookId: 'rid-1',
        lastRead: DateTime.utc(2025, 1, 2),
        progress: 0.42,
        currentCharacterIndex: 100,
        lastVisibleCharacterIndex: 99,
      );
      await service.saveReadingProgress(progress);
      final loaded = await service.getReadingProgress('rid-1');
      expect(loaded, isNotNull);
      expect(loaded!.bookId, progress.bookId);
      expect(loaded.progress, progress.progress);
      expect(loaded.currentCharacterIndex, progress.currentCharacterIndex);
      expect(loaded.lastVisibleCharacterIndex, progress.lastVisibleCharacterIndex);
    });

    test('getReadingProgress returns null for unknown book', () async {
      expect(await service.getReadingProgress('unknown'), isNull);
    });
  });

  group('BookService import from generated EPUB', () {
    test('importTxt adds a book with deterministic id from content', () async {
      final txt = File('${tempRoot.path}/chapter_one.txt');
      await txt.writeAsString(
        'First line.\nSecond line with enough text for epub metadata.',
      );

      final book = await service.importTxt(txt);

      expect(book.title, isNotEmpty);
      expect(book.author, isNotEmpty);
      expect(book.filePath, isNotEmpty);
      expect(await File(book.filePath).exists(), isTrue);

      final bytes = await File(book.filePath).readAsBytes();
      final expectedId = sha256.convert(bytes).toString().substring(0, 32);
      expect(book.id, expectedId);

      await RagIndexingService().stopIndexing(book.id);

      final all = await service.getAllBooks();
      expect(all.map((b) => b.id), contains(book.id));
    });

    test('importing same EPUB bytes again returns existing book', () async {
      final txt = File('${tempRoot.path}/stable.txt');
      await txt.writeAsString('Same content every time. Hello reader.');

      final epubPath = '${tempRoot.path}/stable.epub';
      await TxtToEpubConverter().convertToEpub(
        txtFile: txt,
        outputEpubPath: epubPath,
      );

      final first = await service.importEpub(File(epubPath));
      await RagIndexingService().stopIndexing(first.id);
      final second = await service.importEpub(File(epubPath));
      await RagIndexingService().stopIndexing(second.id);

      expect(second.id, first.id);

      final all = await service.getAllBooks();
      expect(all.where((b) => b.id == first.id).length, 1);
    });
  });

  group('BookService loadEpubBook', () {
    test('throws for empty path', () async {
      expect(
        () => service.loadEpubBook(''),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('BookService addOrUpdateBook', () {
    test('adds a new book that can be retrieved via getAllBooks', () async {
      final book = Book(
        id: 'add-test-1',
        title: 'Added Book',
        author: 'Author',
        filePath: '${tempRoot.path}/add-test-1.epub',
        dateAdded: DateTime.utc(2025, 1, 1),
      );
      await service.addOrUpdateBook(book);
      final all = await service.getAllBooks();
      expect(all.any((b) => b.id == book.id), isTrue);
    });

    test('updates an existing book in place', () async {
      final original = Book(
        id: 'update-test-1',
        title: 'Old Title',
        author: 'Author',
        filePath: '${tempRoot.path}/update-test-1.epub',
        dateAdded: DateTime.utc(2025, 1, 1),
      );
      await service.addOrUpdateBook(original);

      final updated = Book(
        id: 'update-test-1',
        title: 'New Title',
        author: 'Author',
        filePath: '${tempRoot.path}/update-test-1.epub',
        dateAdded: DateTime.utc(2025, 1, 1),
        isValid: true,
      );
      await service.addOrUpdateBook(updated);

      final all = await service.getAllBooks();
      final found = all.where((b) => b.id == 'update-test-1');
      expect(found.length, 1);
      expect(found.single.title, 'New Title');
      expect(found.single.isValid, isTrue);
    });
  });

  group('BookService deleteBook', () {
    test('removes book from getAllBooks', () async {
      // Create an EPUB file on disk for the book
      final epubFile = File('${tempRoot.path}/del-test-1.epub');
      await epubFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);

      final book = Book(
        id: 'del-test-1',
        title: 'To Delete',
        author: 'Author',
        filePath: epubFile.path,
        dateAdded: DateTime.utc(2025, 2, 1),
      );
      await service.addOrUpdateBook(book);
      expect((await service.getAllBooks()).any((b) => b.id == book.id), isTrue);

      await service.deleteBook(book);

      final all = await service.getAllBooks();
      expect(all.any((b) => b.id == book.id), isFalse);
    });

    test('deletes the EPUB file from disk', () async {
      final epubFile = File('${tempRoot.path}/del-epub-test.epub');
      await epubFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);

      final book = Book(
        id: 'del-epub-test',
        title: 'Delete EPUB',
        author: 'Author',
        filePath: epubFile.path,
        dateAdded: DateTime.utc(2025, 2, 1),
      );
      await service.addOrUpdateBook(book);
      expect(await epubFile.exists(), isTrue);

      await service.deleteBook(book);

      expect(await epubFile.exists(), isFalse);
    });

    test('deletes the cover file from disk', () async {
      final epubFile = File('${tempRoot.path}/del-cover-test.epub');
      await epubFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);
      final coverFile = File('${tempRoot.path}/del-cover-test.png');
      await coverFile.writeAsBytes([0x89, 0x50, 0x4E, 0x47]); // PNG header

      final book = Book(
        id: 'del-cover-test',
        title: 'Delete Cover',
        author: 'Author',
        filePath: epubFile.path,
        coverImagePath: coverFile.path,
        dateAdded: DateTime.utc(2025, 2, 1),
      );
      await service.addOrUpdateBook(book);
      expect(await coverFile.exists(), isTrue);

      await service.deleteBook(book);

      expect(await coverFile.exists(), isFalse);
    });

    test('does not throw when EPUB file is already missing', () async {
      final book = Book(
        id: 'del-missing-epub',
        title: 'Missing EPUB',
        author: 'Author',
        filePath: '${tempRoot.path}/nonexistent.epub',
        dateAdded: DateTime.utc(2025, 2, 1),
      );
      await service.addOrUpdateBook(book);

      // Should complete without throwing even though file doesn't exist
      await expectLater(service.deleteBook(book), completes);
    });

    test('clears reading progress for deleted book', () async {
      final epubFile = File('${tempRoot.path}/del-progress-test.epub');
      await epubFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);

      final book = Book(
        id: 'del-progress-test',
        title: 'Progress Test',
        author: 'Author',
        filePath: epubFile.path,
        dateAdded: DateTime.utc(2025, 2, 1),
      );
      await service.addOrUpdateBook(book);

      final progress = ReadingProgress(
        bookId: book.id,
        lastRead: DateTime.utc(2025, 3, 1),
        progress: 0.5,
        currentCharacterIndex: 500,
        lastVisibleCharacterIndex: 499,
      );
      await service.saveReadingProgress(progress);
      expect(await service.getReadingProgress(book.id), isNotNull);

      await service.deleteBook(book);

      expect(await service.getReadingProgress(book.id), isNull);
    });
  });
}
