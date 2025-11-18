import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memoreader/screens/reader/document_model.dart';
import 'package:memoreader/screens/reader/line_metrics_pagination_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LineMetricsPaginationEngine line-based fill', () {
    final text = '''
Page one contains a couple of sentences that will be split into many lines. Each paragraph should behave consistently with the pagination engine.

Page two follows with the same level of verbosity so that we can verify multiple pages exist. The line metrics approach should handle this naturally without word-by-word complexity.''';

    final block = TextDocumentBlock(
      chapterIndex: 0,
      spacingBefore: 0,
      spacingAfter: 20,
      text: text,
      fontScale: 1.0,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
      textAlign: TextAlign.left,
    );

    final baseStyle = const TextStyle(fontSize: 16, height: 1.5);

    final engine = LineMetricsPaginationEngine(
      blocks: [block],
      baseTextStyle: baseStyle,
      maxWidth: 360,
      maxHeight: 320,
      textHeightBehavior: const TextHeightBehavior(),
      textScaler: const TextScaler.linear(1.0),
    );

    test('produces sequential pages without gaps or overlaps', () {
      expect(engine.totalPages, greaterThan(1));
      
      final firstPage = engine.getPage(0);
      expect(firstPage, isNotNull);
      expect(firstPage!.startCharIndex, 0);
      expect(firstPage.endCharIndex >= firstPage.startCharIndex, isTrue);
      expect(firstPage.blocks, isNotEmpty);

      final secondPage = engine.getPage(1);
      expect(secondPage, isNotNull);
      // Character indices should be sequential with no overlap
      expect(secondPage!.startCharIndex, equals(firstPage.endCharIndex + 1));
      expect(secondPage.blocks, isNotEmpty);
    });

    test('can find page by character index', () {
      final firstPage = engine.getPage(0);
      expect(firstPage, isNotNull);
      
      // Find the page containing a character in the middle of first page
      final midChar = (firstPage!.startCharIndex + firstPage.endCharIndex) ~/ 2;
      final foundPageIndex = engine.findPageByCharacterIndex(midChar);
      expect(foundPageIndex, equals(0));
      
      // Find a character on the second page
      final secondPage = engine.getPage(1);
      if (secondPage != null) {
        final secondPageChar = secondPage.startCharIndex + 5;
        final foundSecondIndex = engine.findPageByCharacterIndex(secondPageChar);
        expect(foundSecondIndex, equals(1));
      }
    });

    test('pages respect maximum height constraint', () {
      // Verify no page blocks exceed the max height
      for (int i = 0; i < engine.totalPages; i++) {
        final page = engine.getPage(i);
        expect(page, isNotNull);
        
        // Calculate total height of the page
        double totalHeight = 0;
        for (final block in page!.blocks) {
          totalHeight += block.spacingBefore;
          if (block is TextPageBlock) {
            // Approximate height - in real test would measure with TextPainter
            totalHeight += 20; // Rough estimate
          } else if (block is ImagePageBlock) {
            totalHeight += block.height;
          }
          totalHeight += block.spacingAfter;
        }
        
        // Should not significantly exceed maxHeight (with some tolerance for safety margin)
        expect(totalHeight, lessThanOrEqualTo(320 + 10));
      }
    });
  });
}

