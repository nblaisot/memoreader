import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/services/book_service.dart';
import 'package:memoreader/widgets/book_cover_image.dart';
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

/// Minimal valid 1x1 PNG (for [Image.file] decode in widget tests).
final Uint8List k1x1Png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathProviderPlatform savedPathProvider;
  final service = BookService();

  setUp(() async {
    savedPathProvider = PathProviderPlatform.instance;
    tempRoot = Directory.systemTemp.createTempSync('memoreader_drive_cover_');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    PathProviderPlatform.instance = savedPathProvider;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('Drive cover download contract (disk + prefs)', () {
    test('after simulated EPUB+cover write, cover path exists and is non-empty',
        () async {
      const id = '15a82f4d92da027243f4a08d27f4e712';
      final booksDir = await service.getBooksDirectory();
      final coversDir = await service.getCoversDirectory();
      final epubPath = '$booksDir/$id.epub';
      final coverPath = '$coversDir/$id.png';

      final book = Book(
        id: id,
        title: 'Synced Book',
        author: 'Author',
        filePath: epubPath,
        coverImagePath: coverPath,
        dateAdded: DateTime.utc(2026, 3, 29),
        isValid: true,
      );
      await service.addOrUpdateBook(book);

      await File(epubPath).writeAsBytes([0x50, 0x4B, 0x03, 0x04]);
      await Directory(coversDir).create(recursive: true);
      await File(coverPath).writeAsBytes(k1x1Png);

      final loaded = await service.getAllBooks();
      expect(loaded, hasLength(1));
      final b = loaded.single;
      expect(b.coverImagePath, coverPath);
      final f = File(b.coverImagePath!);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(0));
    });

    test('book with metadata cover path but no file on disk has missing cover',
        () async {
      const id = 'no-local-cover';
      final booksDir = await service.getBooksDirectory();
      final coversDir = await service.getCoversDirectory();
      final epubPath = '$booksDir/$id.epub';
      final coverPath = '$coversDir/$id.png';

      await File(epubPath).writeAsBytes([0x50, 0x4B, 0x03, 0x04]);
      // Intentionally do not write coverPath

      final book = Book(
        id: id,
        title: 'No Cover File',
        author: 'A',
        filePath: epubPath,
        coverImagePath: coverPath,
        dateAdded: DateTime.utc(2026, 3, 29),
        isValid: true,
      );
      await service.addOrUpdateBook(book);

      expect(File(coverPath).existsSync(), isFalse);
    });
  });

  group('BookCoverImage', () {
    testWidgets('invalid book does not build Image.file (no stuck error state)',
        (tester) async {
      final book = Book(
        id: 'inv',
        title: 'T',
        author: 'A',
        filePath: '/tmp/missing.epub',
        coverImagePath: '/tmp/missing.png',
        dateAdded: DateTime.utc(2026, 1, 1),
        isValid: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 160,
                child: BookCoverImage(book: book),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(Image), findsNothing);
      expect(find.byType(BookDefaultCover), findsOneWidget);
    });
  });
}
