import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memoreader/screens/reader/block_height_measurer.dart';
import 'package:memoreader/screens/reader/html_blocks.dart';
import 'package:memoreader/screens/reader/paginator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('On-demand paginator', () {
    final baseStyle = const TextStyle(fontSize: 16, height: 1.4);

    test('splits paragraphs without overflow', () {
      final blocks = List.generate(
        3,
        (i) => ParagraphBlock(text: 'Paragraph $i ' * 40),
      );
      final measurer = BlockHeightMeasurer(
        maxWidth: 320,
        pageHeight: 220,
        baseStyle: baseStyle,
        devicePixelRatio: 2.0,
      );
      final paginator = Paginator(
        blocks: blocks,
        pageHeight: 220,
        measurer: measurer,
      );

      final firstPage = paginator.pageFrom(0)!;
      expect(firstPage.blocks, isNotEmpty);
      expect(firstPage.nextBlockIndex, greaterThan(0));

      final secondPage = paginator.pageFrom(firstPage.nextBlockIndex)!;
      expect(secondPage.startBlockIndex, equals(firstPage.nextBlockIndex));
    });

    test('does not exceed page height for images', () {
      final imageBlock = ImageBlock(
        bytes: List<int>.filled(10, 0),
        intrinsicWidth: 2000,
        intrinsicHeight: 2000,
      );
      final measurer = BlockHeightMeasurer(
        maxWidth: 300,
        pageHeight: 240,
        baseStyle: baseStyle,
        devicePixelRatio: 2.0,
      );
      final paginator = Paginator(
        blocks: [imageBlock],
        pageHeight: 240,
        measurer: measurer,
      );

      final page = paginator.pageFrom(0)!;
      final measured = measurer.measure(imageBlock);
      expect(measured <= 240, isTrue);
      expect(page.blocks.first, same(imageBlock));
    });

    test('previousStart returns earlier page boundary', () {
      final blocks = [
        ParagraphBlock(text: 'Intro ' * 20),
        ParagraphBlock(text: 'Body ' * 40),
        ParagraphBlock(text: 'Tail ' * 40),
      ];
      final measurer = BlockHeightMeasurer(
        maxWidth: 300,
        pageHeight: 200,
        baseStyle: baseStyle,
        devicePixelRatio: 2.0,
      );
      final paginator = Paginator(
        blocks: blocks,
        pageHeight: 200,
        measurer: measurer,
      );

      final first = paginator.pageFrom(0)!;
      final second = paginator.pageFrom(first.nextBlockIndex)!;
      final prevStart = paginator.previousStart(second.startBlockIndex);
      expect(prevStart, equals(first.startBlockIndex));
    });
  });
}
