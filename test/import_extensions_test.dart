import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/utils/import_extensions.dart';

void main() {
  group('isAllowedBookImportPath', () {
    test('accepts epub txt pdf case-insensitive', () {
      expect(isAllowedBookImportPath('/books/a.epub'), isTrue);
      expect(isAllowedBookImportPath('/x.TXT'), isTrue);
      expect(isAllowedBookImportPath('doc.PDF'), isTrue);
    });

    test('rejects other extensions', () {
      expect(isAllowedBookImportPath('/a.mobi'), isFalse);
      expect(isAllowedBookImportPath('/a'), isFalse);
      expect(isAllowedBookImportPath(''), isFalse);
    });
  });

  group('extensionFromPath', () {
    test('returns lowercase extension without dot', () {
      expect(extensionFromPath('/foo/bar/file.EPUB'), 'epub');
      expect(extensionFromPath('name.pdf'), 'pdf');
    });

    test('returns empty when no extension', () {
      expect(extensionFromPath('/noext'), '');
      expect(extensionFromPath(''), '');
      expect(extensionFromPath('trailing.'), '');
    });
  });
}
