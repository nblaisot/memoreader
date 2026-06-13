import 'dart:io';

import 'package:epubx/epubx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/epub_content_resolver.dart';
import 'package:memoreader/utils/html_text_extractor.dart';

void main() {
  group('EpubContentResolver', () {
    test('includes spine body files missing from epub.Chapters', () async {
      final epub = EpubBook()
        ..Schema = (EpubSchema()
          ..Package = (EpubPackage()
            ..Manifest = (EpubManifest()
              ..Items = [
                EpubManifestItem()
                  ..Id = 'title'
                  ..Href = 'title.xhtml'
                  ..MediaType = 'application/xhtml+xml',
                EpubManifestItem()
                  ..Id = 'body'
                  ..Href = 'body.xhtml'
                  ..MediaType = 'application/xhtml+xml',
              ])
            ..Spine = (EpubSpine()
              ..Items = [
                EpubSpineItemRef()..IdRef = 'title',
                EpubSpineItemRef()..IdRef = 'body',
              ])))
        ..Chapters = [
          EpubChapter()
            ..Title = 'Chapter One'
            ..ContentFileName = 'title.xhtml'
            ..HtmlContent =
                '<html><body><h1>Chapter One</h1><p>1984</p></body></html>',
        ]
        ..Content = (EpubContent()
          ..Html = {
            'title.xhtml': (EpubTextContentFile()
              ..FileName = 'title.xhtml'
              ..Content =
                  '<html><body><h1>Chapter One</h1><p>1984</p></body></html>'),
            'body.xhtml': (EpubTextContentFile()
              ..FileName = 'body.xhtml'
              ..Content =
                  '<html><body><p>C\'est la cour de récréation d\'un lycée.</p></body></html>'),
          });

      final resolution = EpubContentResolver.resolve(epub);

      expect(resolution.sections, hasLength(2));
      expect(resolution.sections.first.contentFileKey, 'title.xhtml');
      expect(resolution.sections.last.contentFileKey, 'body.xhtml');
      expect(
        HtmlTextExtractor.extract(resolution.sections.last.html),
        contains('cour de récréation'),
      );
      expect(resolution.chapters, hasLength(1));
      expect(resolution.chapters.first.title, 'Chapter One');
    });

    test('does not page-break body sections that follow title stubs', () {
      final epub = EpubBook()
        ..Schema = (EpubSchema()
          ..Package = (EpubPackage()
            ..Manifest = (EpubManifest()
              ..Items = [
                EpubManifestItem()
                  ..Id = 'title'
                  ..Href = 'title.xhtml'
                  ..MediaType = 'application/xhtml+xml',
                EpubManifestItem()
                  ..Id = 'body'
                  ..Href = 'body.xhtml'
                  ..MediaType = 'application/xhtml+xml',
              ])
            ..Spine = (EpubSpine()
              ..Items = [
                EpubSpineItemRef()..IdRef = 'title',
                EpubSpineItemRef()..IdRef = 'body',
              ])))
        ..Chapters = [
          EpubChapter()
            ..Title = 'Chapitre un - 1984'
            ..ContentFileName = 'title.xhtml'
            ..HtmlContent =
                '<html><body><h1>Chapitre un</h1><p>1984</p></body></html>',
        ]
        ..Content = (EpubContent()
          ..Html = {
            'title.xhtml': (EpubTextContentFile()
              ..FileName = 'title.xhtml'
              ..Content =
                  '<html><body><h1>Chapitre un</h1><p>1984</p></body></html>'),
            'body.xhtml': (EpubTextContentFile()
              ..FileName = 'body.xhtml'
              ..Content =
                  '<html><body><p>Long chapter body that should continue in the same column.</p></body></html>'),
          });

      final resolution = EpubContentResolver.resolve(epub);

      expect(resolution.sections.first.pageBreakBefore, isFalse);
      expect(resolution.sections.first.isChapterStart, isTrue);
      expect(resolution.sections.last.pageBreakBefore, isFalse);
      expect(resolution.sections.last.isChapterStart, isFalse);
    });

    test('flattens nested subchapters into readable sections', () {
      final epub = EpubBook()
        ..Schema = (EpubSchema()
          ..Package = (EpubPackage()
            ..Manifest = (EpubManifest()
              ..Items = [
                EpubManifestItem()
                  ..Id = 'parent'
                  ..Href = 'parent.xhtml'
                  ..MediaType = 'application/xhtml+xml',
                EpubManifestItem()
                  ..Id = 'child'
                  ..Href = 'child.xhtml'
                  ..MediaType = 'application/xhtml+xml',
              ])
            ..Spine = (EpubSpine()
              ..Items = [
                EpubSpineItemRef()..IdRef = 'parent',
                EpubSpineItemRef()..IdRef = 'child',
              ])))
        ..Chapters = [
          EpubChapter()
            ..Title = 'Part I'
            ..ContentFileName = 'parent.xhtml'
            ..HtmlContent = '<html><body><h1>Part I</h1></body></html>'
            ..SubChapters = [
              EpubChapter()
                ..Title = 'Section A'
                ..ContentFileName = 'child.xhtml'
                ..HtmlContent =
                    '<html><body><p>Nested section content.</p></body></html>',
            ],
        ]
        ..Content = (EpubContent()
          ..Html = {
            'parent.xhtml': (EpubTextContentFile()
              ..FileName = 'parent.xhtml'
              ..Content = '<html><body><h1>Part I</h1></body></html>'),
            'child.xhtml': (EpubTextContentFile()
              ..FileName = 'child.xhtml'
              ..Content =
                  '<html><body><p>Nested section content.</p></body></html>'),
          });

      final resolution = EpubContentResolver.resolve(epub);

      expect(resolution.chapters, hasLength(2));
      expect(resolution.sections, hasLength(2));
      expect(
        HtmlTextExtractor.extract(resolution.sections.last.html),
        contains('Nested section content'),
      );
    });

    test('resolves the Besson EPUB with full spine prose', () async {
      final downloads = Directory('/Users/nblaisot/Downloads');
      if (!downloads.existsSync()) {
        return;
      }

      final matches = downloads
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.epub') &&
                file.path.contains('9782901096757'),
          )
          .toList();
      if (matches.isEmpty) {
        return;
      }

      final bytes = await matches.first.readAsBytes();
      final book = await EpubReader.readBook(bytes);
      final resolution = EpubContentResolver.resolve(book);

      expect(resolution.sections.length, greaterThan(6));
      final combined = resolution.sections
          .map((section) => HtmlTextExtractor.extract(section.html))
          .join('\n');
      expect(combined.length, greaterThan(100000));
      expect(combined, contains('cour de récréation'));
      expect(combined, contains('Chapitre un'));
      expect(combined, contains('Chapitre deux'));
      expect(combined, contains('Chapitre trois'));

      final bodySection = resolution.sections.firstWhere(
        (section) => section.contentFileKey == 'EP008_chap_01.htm',
      );
      expect(bodySection.pageBreakBefore, isFalse);
      expect(bodySection.chapterIndex, 3);
    });
  });
}
