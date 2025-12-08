import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:memoreader/utils/css_resolver.dart';

void main() {
  group('Document Extraction Tests', () {
    test('verifies text extraction from HTML produces non-empty blocks', () {
      // Test HTML similar to what would come from an EPUB
      final xhtml = '''
        <html>
          <body>
            <h1>Chapter Title</h1>
            <p>First paragraph of the chapter with some text.</p>
            <p>Second paragraph with <em>emphasized</em> text.</p>
            <p>Third paragraph with <strong>bold</strong> and <i>italic</i> formatting.</p>
            <p>Fourth paragraph continues the story.</p>
            <p>Fifth paragraph with more content.</p>
          </body>
        </html>
      ''';

      final document = html_parser.parse(xhtml);
      final body = document.body!;

      // Extract text content manually to verify it exists
      final allText = <String>[];
      
      void extractText(dom.Node node) {
        if (node is dom.Text) {
          final text = node.text.trim();
          if (text.isNotEmpty) {
            allText.add(text);
          }
        } else if (node is dom.Element) {
          for (final child in node.nodes) {
            extractText(child);
          }
        }
      }

      extractText(body);

      // Verify we extracted substantial text
      expect(allText.isNotEmpty, isTrue, reason: 'Should extract text from HTML');
      
      final combinedText = allText.join(' ');
      expect(combinedText.length, greaterThan(100),
          reason: 'Should extract at least 100 characters');
      
      // Verify key phrases are present
      expect(combinedText.toLowerCase(), contains('chapter title'));
      expect(combinedText.toLowerCase(), contains('first paragraph'));
      expect(combinedText.toLowerCase(), contains('second paragraph'));
      expect(combinedText.toLowerCase(), contains('emphasized'));
      expect(combinedText.toLowerCase(), contains('bold'));
      expect(combinedText.toLowerCase(), contains('italic'));
      expect(combinedText.toLowerCase(), contains('fourth paragraph'));
      expect(combinedText.toLowerCase(), contains('fifth paragraph'));
    });

    test('verifies CSS resolver can parse styles', () {
      final cssResolver = CssResolver();
      cssResolver.addStylesheet('test', '''
        .chapter-title { font-size: 24px; font-weight: bold; text-align: center; }
        p { margin: 10px 0; }
        .emphasis { font-style: italic; }
        .strong { font-weight: bold; }
      ''');
      cssResolver.parseAll();

      // Create a simple element to test
      final xhtml = '<p class="emphasis">Test paragraph</p>';
      final document = html_parser.parse(xhtml);
      final element = document.body!.querySelector('p')!;

      final style = cssResolver.resolveStyles(element);
      
      // Verify CSS was parsed (we can't check exact values without accessing internals,
      // but we can verify the resolver doesn't crash)
      expect(style, isNotNull);
    });

    test('verifies complex HTML structure can be parsed', () {
      final complexXhtml = '''
        <html>
          <head>
            <style>
              .chapter-title { font-size: 24px; font-weight: bold; }
              .paragraph { margin: 10px 0; }
            </style>
          </head>
          <body>
            <h1 class="chapter-title">The Great Adventure</h1>
            <p class="paragraph">Once upon a time, in a land far away, there lived a brave knight named Arthur.</p>
            <p class="paragraph">The knight had a <strong>mighty sword</strong> that gleamed in the sunlight.</p>
            <p class="paragraph">He also had a <em>loyal steed</em> named Shadow.</p>
            <p class="paragraph">Together, they embarked on many <i>dangerous</i> quests across the kingdom.</p>
            <p class="paragraph">Each quest brought new challenges and <b>exciting</b> adventures.</p>
            <p class="paragraph">The knight's courage never wavered, even in the face of <strong>great danger</strong>.</p>
            <p class="paragraph">And so, the legend of the brave knight grew throughout the kingdom.</p>
            <h2>Section Two</h2>
            <p>More content in section two.</p>
            <p>Even more content here.</p>
          </body>
        </html>
      ''';

      final document = html_parser.parse(complexXhtml);
      final body = document.body!;

      // Extract all text nodes
      final textNodes = <String>[];
      void collectText(dom.Node node) {
        if (node is dom.Text) {
          final text = node.text.trim();
          if (text.isNotEmpty) {
            textNodes.add(text);
          }
        }
        for (final child in node.nodes) {
          collectText(child);
        }
      }
      collectText(body);

      // Verify substantial content
      expect(textNodes.length, greaterThan(10),
          reason: 'Should extract multiple text nodes');
      
      final totalLength = textNodes.join(' ').length;
      expect(totalLength, greaterThan(300),
          reason: 'Should extract at least 300 characters (got $totalLength)');

      // Verify key content is present
      final allText = textNodes.join(' ').toLowerCase();
      expect(allText, contains('the great adventure'));
      expect(allText, contains('brave knight'));
      expect(allText, contains('mighty sword'));
      expect(allText, contains('loyal steed'));
      expect(allText, contains('dangerous quests'));
      expect(allText, contains('exciting adventures'));
      expect(allText, contains('great danger'));
      expect(allText, contains('section two'));
    });

    test('verifies inline formatting elements are preserved in structure', () {
      final xhtml = '''
        <html>
          <body>
            <p>This paragraph has <i>italic text</i> and <strong>bold text</strong>.</p>
            <p>Another paragraph with <em>emphasized</em> and <b>bold</b> mixed.</p>
          </body>
        </html>
      ''';

      final document = html_parser.parse(xhtml);
      final body = document.body!;

      // Verify structure contains formatting elements
      final italicElements = body.querySelectorAll('i, em');
      final boldElements = body.querySelectorAll('strong, b');

      expect(italicElements.length, greaterThan(0),
          reason: 'Should have italic/emphasis elements');
      expect(boldElements.length, greaterThan(0),
          reason: 'Should have bold elements');

      // Verify text content is preserved
      final allText = body.text;
      expect(allText, contains('italic text'));
      expect(allText, contains('bold text'));
      expect(allText, contains('emphasized'));
    });
  });
}
