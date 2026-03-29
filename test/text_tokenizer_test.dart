import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/utils/text_tokenizer.dart';

void main() {
  group('tokenizePreservingWhitespace', () {
    test('splits words and preserves spaces', () {
      expect(
        tokenizePreservingWhitespace('a  bb'),
        ['a', '  ', 'bb'],
      );
    });

    test('empty string yields empty list', () {
      expect(tokenizePreservingWhitespace(''), isEmpty);
    });

    test('whitespace only', () {
      expect(tokenizePreservingWhitespace(' \n '), [' \n ']);
      final t = tokenizePreservingWhitespace('\t');
      expect(t.length, 1);
      expect(t.first, '\t');
    });
  });

  group('tokenizeWithSpans', () {
    test('offsets cover full string', () {
      const s = 'hi there';
      final spans = tokenizeWithSpans(s);
      expect(spans.first.start, 0);
      expect(spans.last.end, s.length);
    });

    test('single word', () {
      final spans = tokenizeWithSpans('x');
      expect(spans.length, 1);
      expect(spans.single.text, 'x');
      expect(spans.single.length, 1);
    });
  });
}
