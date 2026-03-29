import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/utils/html_text_extractor.dart';

void main() {
  group('HtmlTextExtractor', () {
    test('returns empty string when body is missing', () {
      expect(HtmlTextExtractor.extract('<html></html>'), '');
    });

    test('extracts paragraph text with paragraph breaks', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><p>Hello</p><p>World</p></body></html>',
      );
      expect(out.trim(), 'Hello\n\nWorld');
    });

    test('strips script and style content', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><script>x</script><style>.a{}</style><p>Visible</p></body></html>',
      );
      expect(out.trim(), 'Visible');
    });

    test('br inserts newline', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><p>a</p><br/><p>b</p></body></html>',
      );
      expect(out.contains('a'), isTrue);
      expect(out.contains('b'), isTrue);
      expect(out.contains('\n'), isTrue);
    });

    test('img inserts object replacement placeholder', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><p>Before</p><img src="x.png"/><p>After</p></body></html>',
      );
      expect(out.contains('Before'), isTrue);
      expect(out.contains('After'), isTrue);
      expect(out.contains('\uFFFC'), isTrue);
    });

    test('unordered list uses bullet prefix', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><ul><li>One</li><li>Two</li></ul></body></html>',
      );
      expect(out, contains('• One'));
      expect(out, contains('• Two'));
    });

    test('ordered list uses numeric prefix', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><ol><li>First</li><li>Second</li></ol></body></html>',
      );
      expect(out, contains('1. First'));
      expect(out, contains('2. Second'));
    });

    test('headings and block elements schedule paragraph structure', () {
      final out = HtmlTextExtractor.extract(
        '<html><body><h1>Title</h1><p>Body text.</p></body></html>',
      );
      expect(out, contains('Title'));
      expect(out, contains('Body text.'));
    });
  });

  group('normalizeWhitespace', () {
    test('collapses spaces and normalizes nbsp', () {
      expect(normalizeWhitespace('a  \t b\u00a0c'), 'a b c');
    });

    test('normalizes CRLF and trims', () {
      expect(normalizeWhitespace('  x\r\ny  '), 'x\ny');
    });

    test('caps excessive newlines', () {
      expect(normalizeWhitespace('a\n\n\n\nb'), 'a\n\nb');
    });
  });
}
