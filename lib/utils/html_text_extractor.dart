import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

/// Provides utilities to extract reader-aligned plain text from HTML content.
///
/// The reader pagination engine normalizes whitespace and handles special
/// elements like lists and images before laying out text. Summary generation
/// needs to apply the exact same rules so that character offsets match what the
/// reader reports. This helper reproduces the reader's normalization logic and
/// inserts placeholders for non-text content (like images) so the resulting
/// string can be mapped accurately to reading positions.
class HtmlTextExtractor {
  HtmlTextExtractor._(this._buffer);

  final StringBuffer _buffer;

  /// Extract normalized text matching the reader's behavior.
  static String extract(String html) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) {
      return '';
    }

    final buffer = StringBuffer();
    final extractor = HtmlTextExtractor._(buffer);

    for (final node in body.nodes) {
      extractor._walk(node);
    }

    return buffer.toString();
  }

  void _walk(dom.Node node) {
    if (node is dom.Element) {
      final name = node.localName?.toLowerCase();
      switch (name) {
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          _addTextBlock(node.text);
          return;
        case 'p':
        case 'div':
        case 'section':
        case 'article':
        case 'blockquote':
          _addTextBlock(node.text);
          for (final child in node.nodes) {
            _walk(child);
          }
          return;
        case 'ul':
        case 'ol':
          final ordered = name == 'ol';
          int counter = 1;
          for (final child
              in node.children.where((element) => element.localName == 'li')) {
            final text = normalizeWhitespace(child.text);
            if (text.isEmpty) {
              continue;
            }
            final bullet = ordered ? '$counter. ' : '• ';
            _addRawText('$bullet$text');
            counter++;
          }
          return;
        case 'img':
          _addImagePlaceholder();
          return;
        case 'br':
          // Reader treats explicit line breaks as empty blocks, which results in
          // no additional characters. Nothing to append here.
          return;
        default:
          for (final child in node.nodes) {
            _walk(child);
          }
          return;
      }
    } else if (node is dom.Text) {
      _addTextBlock(node.text);
    } else {
      for (final child in node.nodes) {
        _walk(child);
      }
    }
  }

  void _addTextBlock(String text) {
    final normalized = normalizeWhitespace(text);
    if (normalized.isEmpty) {
      return;
    }
    _buffer.write(normalized);
  }

  void _addRawText(String text) {
    if (text.isEmpty) {
      return;
    }
    _buffer.write(text);
  }

  void _addImagePlaceholder() {
    // The reader pagination engine advances the character index by one for
    // images. Insert a single object replacement character so that the summary
    // extractor stays in sync with the stored reading positions.
    _buffer.write('￼');
  }
}

/// Normalize whitespace while preserving line breaks and paragraph structure.
///
/// This mirrors the reader's normalization logic so text extracted for
/// summaries has the same character offsets as the rendered reader content.
String normalizeWhitespace(String text) {
  var normalized = text.replaceAll(RegExp(r'\r\n'), '\n');
  normalized = normalized.replaceAll(RegExp(r'\r'), '\n');
  normalized = normalized.replaceAll(RegExp(r'[ \t]+'), ' ');
  normalized = normalized.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return normalized.trim();
}
