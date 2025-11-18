import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

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
  bool _pendingParagraphBreak = false;

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

    extractor._flushPendingBreak();
    return buffer.toString();
  }

  void _walk(dom.Node node) {
    if (node is dom.Element) {
      final name = node.localName?.toLowerCase();
      if (name == null || _isLayoutArtifact(node)) {
        return;
      }

      switch (name) {
        case 'style':
        case 'script':
          return;
        case 'br':
          _buffer.write('\n');
          return;
        case 'img':
          _flushPendingBreak();
          _addImagePlaceholder();
          _scheduleParagraphBreak();
          return;
        case 'ul':
        case 'ol':
          _ensureParagraphBoundary();
          final ordered = name == 'ol';
          int counter = 1;
          for (final child
              in node.children.where((element) => element.localName == 'li')) {
            final text = normalizeWhitespace(child.text);
            if (text.isEmpty) {
              continue;
            }
            final bullet = ordered ? '$counter. ' : '• ';
            _buffer.write('$bullet$text');
            _buffer.write('\n');
            counter++;
          }
          _scheduleParagraphBreak();
          return;
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
        case 'p':
        case 'div':
        case 'section':
        case 'article':
        case 'blockquote':
        case 'pre':
          _ensureParagraphBoundary();
          for (final child in node.nodes) {
            _walk(child);
          }
          _scheduleParagraphBreak();
          return;
        default:
          for (final child in node.nodes) {
            _walk(child);
          }
          return;
      }
    } else if (node is dom.Text) {
      _buffer.write(_cleanText(node.text));
    } else {
      for (final child in node.nodes) {
        _walk(child);
      }
    }
  }

  void _ensureParagraphBoundary() {
    if (_buffer.isNotEmpty) {
      _flushPendingBreak();
    }
  }

  void _scheduleParagraphBreak() {
    _pendingParagraphBreak = true;
  }

  void _flushPendingBreak() {
    if (_pendingParagraphBreak &&
        !_buffer.toString().endsWith('\n\n') &&
        _buffer.isNotEmpty) {
      if (_buffer.toString().endsWith('\n')) {
        _buffer.write('\n');
      } else {
        _buffer.write('\n\n');
      }
    }
    _pendingParagraphBreak = false;
  }

  String _cleanText(String text) {
    final normalized = normalizeWhitespace(text);
    _pendingParagraphBreak = false;
    return normalized;
  }

  bool _isLayoutArtifact(dom.Element element) {
    final classAttr = element.className.toLowerCase();
    if (classAttr.contains('pagebreak') || classAttr.contains('pagenum')) {
      return true;
    }

    final style = element.attributes['style']?.toLowerCase() ?? '';
    if (style.contains('page-break') || style.contains('break-before') || style.contains('break-after')) {
      return true;
    }
    if (style.contains('position:absolute') || style.contains('position: fixed')) {
      return true;
    }
    if (style.contains(RegExp(r'(width|height)\s*:\s*\d+px'))) {
      return true;
    }
    if (style.contains(RegExp(r'\b(top|left|right|bottom)\s*:'))) {
      return true;
    }

    return false;
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
  normalized = normalized.replaceAll('\u00a0', ' ');
  normalized = normalized.replaceAll(RegExp(r'[ \t]+'), ' ');
  normalized = normalized.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return normalized.trim();
}
