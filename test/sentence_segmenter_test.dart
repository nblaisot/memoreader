import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/utils/sentence_segmenter.dart';

void main() {
  group('SentenceSegmenter.split', () {
    test('empty and whitespace yield no spans', () {
      expect(SentenceSegmenter.split(''), isEmpty);
      expect(SentenceSegmenter.split('   '), isEmpty);
    });

    test('no punctuation falls back to whole text trimmed', () {
      final spans = SentenceSegmenter.split('Hello world');
      expect(spans.length, 1);
      expect(spans.first.text, 'Hello world');
      expect(spans.first.start, 0);
      expect(spans.first.end, 'Hello world'.length);
    });

    test('splits on period followed by space', () {
      final spans = SentenceSegmenter.split('First. Second! Third?');
      expect(spans.length, greaterThanOrEqualTo(3));
      expect(spans.map((s) => s.text).join(' '), contains('First.'));
      expect(spans.map((s) => s.text).join(' '), contains('Second!'));
      expect(spans.map((s) => s.text).join(' '), contains('Third?'));
    });

    test('captures trailing fragment after last match', () {
      final spans = SentenceSegmenter.split('Done. More text without end');
      final texts = spans.map((s) => s.text).toList();
      expect(texts.any((t) => t.contains('More text without end')), isTrue);
    });
  });
}
