import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memoreader/screens/reader/block_height_measurer.dart';
import 'package:memoreader/screens/reader/html_blocks.dart';
import 'package:memoreader/screens/reader/paginator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pages remain sequential when requesting on demand', () {
    final longParagraph = ParagraphBlock(text: 'Long body ' * 200);
    final blocks = [longParagraph];
    final measurer = BlockHeightMeasurer(
      maxWidth: 360,
      pageHeight: 300,
      baseStyle: const TextStyle(fontSize: 16, height: 1.5),
      devicePixelRatio: 2.0,
    );
    final paginator = Paginator(
      blocks: blocks,
      pageHeight: 300,
      measurer: measurer,
    );

    final page1 = paginator.pageFrom(0)!;
    final page2 = paginator.pageFrom(page1.nextBlockIndex);

    expect(page1.startBlockIndex, 0);
    expect(page2?.startBlockIndex, equals(page1.nextBlockIndex));
    expect(page1.blocks, isNotEmpty);
    expect(page2?.blocks, isNotEmpty);
  });
}
