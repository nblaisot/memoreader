import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'html_blocks.dart';

/// Converts raw HTML into a list of renderable [HtmlBlock]s.
class HtmlBlockParser {
  const HtmlBlockParser();

  List<HtmlBlock> parse(String html) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) return const [];

    final blocks = <HtmlBlock>[];
    var isFirst = true;

    void addTextBlock(
      String text, {
      TextAlign align = TextAlign.start,
      bool isQuote = false,
    }) {
      final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (normalized.isEmpty) return;
      if (isQuote) {
        blocks.add(QuoteBlock(text: normalized)..spacingBefore = isFirst ? 0 : 12);
      } else {
        blocks.add(ParagraphBlock(text: normalized, alignment: align)
          ..spacingBefore = isFirst ? 0 : 8);
      }
      isFirst = false;
    }

    void addHeaderBlock(String text, int level) {
      final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (normalized.isEmpty) return;
      blocks.add(
        HeaderBlock(text: normalized, level: level)
          ..spacingBefore = isFirst ? 0 : 18,
      );
      isFirst = false;
    }

    void addImageBlock(dom.Element element) {
      final src = element.attributes['src'];
      if (src == null || src.isEmpty) return;
      blocks.add(ImageBlock(bytes: const [], source: src));
      isFirst = false;
    }

    void walk(dom.Node node) {
      if (node is dom.Element) {
        final name = node.localName?.toLowerCase();
        switch (name) {
          case 'h1':
          case 'h2':
          case 'h3':
          case 'h4':
          case 'h5':
          case 'h6':
            final level = int.tryParse(name![1]) ?? 3;
            addHeaderBlock(node.text, level);
            return;
          case 'blockquote':
            addTextBlock(node.text, isQuote: true);
            return;
          case 'p':
          case 'div':
          case 'section':
          case 'article':
            addTextBlock(node.text);
            return;
          case 'ul':
          case 'ol':
            var counter = 1;
            final ordered = name == 'ol';
            for (final li in node.children.where((n) => n.localName == 'li')) {
              final bullet = ordered ? '$counter. ' : '• ';
              addTextBlock('$bullet${li.text}');
              counter++;
            }
            return;
          case 'img':
            addImageBlock(node);
            return;
          case 'br':
            addTextBlock('');
            return;
          default:
            for (final child in node.nodes) {
              walk(child);
            }
            return;
        }
      } else if (node is dom.Text) {
        addTextBlock(node.text);
      } else {
        for (final child in node.nodes) {
          walk(child);
        }
      }
    }

    for (final node in body.nodes) {
      walk(node);
    }

    return blocks;
  }
}
