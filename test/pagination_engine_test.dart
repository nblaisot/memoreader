import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/screens/reader/document_model.dart';
import 'package:memoreader/screens/reader/line_metrics_pagination_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LineMetricsPaginationEngine', () {
    test('preserves text when laying out text', () async {
      final blocks = <DocumentBlock>[
        const TextDocumentBlock(
          chapterIndex: 0,
          spacingBefore: 0,
          spacingAfter: 0,
          text: 'Bonjour le monde',
          fontScale: 1.0,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
          textAlign: TextAlign.left,
        ),
      ];

      final engine = await LineMetricsPaginationEngine.create(
        bookId: 'test-book',
        blocks: blocks,
        baseTextStyle: const TextStyle(fontSize: 18, height: 1.4),
        maxWidth: 400,
        maxHeight: 600,
        textHeightBehavior: const TextHeightBehavior(),
        textScaler: const TextScaler.linear(1.0),
        cacheManager: null,
      );

      await engine.ensureWindow(0, radius: 1);
      expect(engine.computedPageCount, greaterThan(0));
      final page = engine.getPage(0);
      expect(page, isNotNull);
      expect(page!.blocks.first, isA<TextPageBlock>());
      final textBlock = page.blocks.first as TextPageBlock;
      expect(textBlock.text, contains('Bonjour le monde'));
    });

    test('images never exceed available height', () async {
      final fakeImage = List<int>.filled(10, 0);
      final blocks = <DocumentBlock>[
        ImageDocumentBlock(
          chapterIndex: 0,
          spacingBefore: 0,
          spacingAfter: 0,
          bytes: Uint8List.fromList(fakeImage),
          intrinsicWidth: 2000,
          intrinsicHeight: 2000,
        ),
      ];

      final engine = await LineMetricsPaginationEngine.create(
        bookId: 'test-image',
        blocks: blocks,
        baseTextStyle: const TextStyle(fontSize: 18, height: 1.4),
        maxWidth: 300,
        maxHeight: 400,
        textHeightBehavior: const TextHeightBehavior(),
        textScaler: const TextScaler.linear(1.0),
        cacheManager: null,
      );

      await engine.ensureWindow(0, radius: 0);
      expect(engine.computedPageCount, greaterThan(0));
      final page = engine.getPage(0);
      expect(page, isNotNull);
      final imageBlock = page!.blocks.first as ImagePageBlock;
      expect(imageBlock.height, lessThanOrEqualTo(400));
    });

    test('can find page by chapter index', () async {
      final blocks = <DocumentBlock>[
        const TextDocumentBlock(
          chapterIndex: 0,
          spacingBefore: 0,
          spacingAfter: 0,
          text: 'Chapter 1 content',
          fontScale: 1.0,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
          textAlign: TextAlign.left,
        ),
        const TextDocumentBlock(
          chapterIndex: 1,
          spacingBefore: 0,
          spacingAfter: 0,
          text: 'Chapter 2 content',
          fontScale: 1.0,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
          textAlign: TextAlign.left,
        ),
      ];

      final engine = await LineMetricsPaginationEngine.create(
        bookId: 'test-chapters',
        blocks: blocks,
        baseTextStyle: const TextStyle(fontSize: 18, height: 1.4),
        maxWidth: 400,
        maxHeight: 600,
        textHeightBehavior: const TextHeightBehavior(),
        textScaler: const TextScaler.linear(1.0),
        cacheManager: null,
      );

      await engine.ensureWindow(0, radius: 1);
      final pageIndex = engine.findPageForChapter(1);
      expect(pageIndex, isNotNull);
      final page = engine.getPage(pageIndex!);
      expect(page, isNotNull);
      expect(page!.chapterIndex, equals(1));
    });
  });
}
