import 'dart:async';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'html_height_measurer_widget.dart';

/// Helper class for dynamic pagination by measuring actual rendered HTML height
/// 
/// This approach measures the actual rendered height of HTML content using
/// GlobalKey and RenderBox, then dynamically splits content to fit each page.
/// This is more accurate than pre-calculating dimensions.
class DynamicPaginationHelper {
  /// Split HTML content into pages by dynamically measuring rendered height
  /// 
  /// This method iteratively builds pages by rendering HTML content and measuring
  /// its actual height until it fits within the available space.
  static Future<List<String>> splitIntoPages({
    required BuildContext context,
    required String htmlContent,
    required double fontSize,
    required double lineHeight,
    required double availableHeight,
    required double availableWidth,
  }) async {
    if (htmlContent.isEmpty) {
      return ['<p>No content available.</p>'];
    }

    try {
      // Parse HTML to get structured content
      final document = html_parser.parse(htmlContent);
      if (document.body == null) {
        return [htmlContent];
      }

      // Extract all text nodes and elements
      final bodyElements = _extractElements(document.body!);
      
      if (bodyElements.isEmpty) {
        return [htmlContent];
      }

      final pages = <String>[];
      final textStyle = TextStyle(
        fontSize: fontSize,
        height: lineHeight,
      );

      int currentElementIndex = 0;
      String currentPageHtml = '';

      // Account for margins (10px top + 10px bottom)
      final margins = 20.0;
      final adjustedHeight = availableHeight - margins;

      while (currentElementIndex < bodyElements.length) {
        final element = bodyElements[currentElementIndex];
        final testHtml = currentPageHtml.isEmpty 
            ? element.outerHtml 
            : currentPageHtml + element.outerHtml;

        // Measure actual rendered height
        final height = await HtmlHeightMeasurer.measureHeight(
          context: context,
          htmlContent: testHtml,
          textStyle: textStyle,
          maxWidth: availableWidth,
        );
        final fits = height <= adjustedHeight;

        if (fits) {
          // Content fits, add element to current page
          currentPageHtml = testHtml;
          currentElementIndex++;
        } else {
          // Content doesn't fit
          if (currentPageHtml.isEmpty) {
            // Single element is too large, split it
            final splitParts = await _splitElementDynamically(
              context: context,
              element: element,
              textStyle: textStyle,
              maxWidth: availableWidth,
              maxHeight: adjustedHeight,
            );
            
            for (int i = 0; i < splitParts.length; i++) {
              if (i < splitParts.length - 1) {
                // Full pages
                pages.add(_wrapContent(splitParts[i]));
              } else {
                // Last part goes to current page
                currentPageHtml = splitParts[i];
              }
            }
            currentElementIndex++;
          } else {
            // Current page is full, save it and start new page
            pages.add(_wrapContent(currentPageHtml));
            currentPageHtml = '';
            // Don't increment - process this element again on new page
          }
        }
      }

      // Add remaining content as last page
      if (currentPageHtml.isNotEmpty) {
        pages.add(_wrapContent(currentPageHtml));
      }

      return pages.isEmpty ? [_wrapContent(htmlContent)] : pages;
    } catch (e) {
      debugPrint('Error in dynamic pagination: $e');
      return [htmlContent];
    }
  }


  /// Split an element dynamically by measuring rendered height
  static Future<List<String>> _splitElementDynamically({
    required BuildContext context,
    required html_dom.Element element,
    required TextStyle textStyle,
    required double maxWidth,
    required double maxHeight,
  }) async {
    final parts = <String>[];
    final elementText = element.text ?? '';
    
    if (elementText.isEmpty) {
      return [element.outerHtml];
    }

    // Try to split at sentence boundaries
    final sentences = elementText.split(RegExp(r'([.!?。！？]\s*)'));
    
    String currentPartText = '';
    String currentPartHtml = '';

    for (int i = 0; i < sentences.length; i++) {
      final sentence = sentences[i];
      final testText = currentPartText.isEmpty ? sentence : currentPartText + sentence;
      
      // Create test HTML with this text
      final testElement = _createElementWithText(element, testText);
      final testHtml = testElement.outerHtml;
      
      // Measure actual rendered height
      final height = await HtmlHeightMeasurer.measureHeight(
        context: context,
        htmlContent: testHtml,
        textStyle: textStyle,
        maxWidth: maxWidth,
      );
      final fits = height <= maxHeight;

      if (fits) {
        currentPartText = testText;
        currentPartHtml = testHtml;
      } else {
        if (currentPartHtml.isNotEmpty) {
          // Current part is full, save it
          parts.add(currentPartHtml);
          currentPartText = sentence;
          currentPartHtml = testElement.outerHtml;
        } else {
          // Single sentence is too large, split by words
          final wordParts = await _splitByWords(
            context: context,
            element: element,
            text: sentence,
            textStyle: textStyle,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          );
          parts.addAll(wordParts);
          currentPartText = '';
          currentPartHtml = '';
        }
      }
    }

    // Add remaining part
    if (currentPartHtml.isNotEmpty) {
      parts.add(currentPartHtml);
    }

    return parts.isEmpty ? [element.outerHtml] : parts;
  }

  /// Split text by words when sentences are too large
  static Future<List<String>> _splitByWords({
    required BuildContext context,
    required html_dom.Element element,
    required String text,
    required TextStyle textStyle,
    required double maxWidth,
    required double maxHeight,
  }) async {
    final parts = <String>[];
    final words = text.split(RegExp(r'\s+'));
    
    String currentPart = '';
    String currentPartHtml = '';

    for (final word in words) {
      final testText = currentPart.isEmpty ? word : '$currentPart $word';
      final testElement = _createElementWithText(element, testText);
      final testHtml = testElement.outerHtml;
      
      // Measure actual rendered height
      final height = await HtmlHeightMeasurer.measureHeight(
        context: context,
        htmlContent: testHtml,
        textStyle: textStyle,
        maxWidth: maxWidth,
      );
      final fits = height <= maxHeight;

      if (fits) {
        currentPart = testText;
        currentPartHtml = testHtml;
      } else {
        if (currentPartHtml.isNotEmpty) {
          parts.add(currentPartHtml);
          currentPart = word;
          currentPartHtml = testElement.outerHtml;
        } else {
          // Even single word is too large (shouldn't happen), just add it
          parts.add(testHtml);
          currentPart = '';
          currentPartHtml = '';
        }
      }
    }

    if (currentPartHtml.isNotEmpty) {
      parts.add(currentPartHtml);
    }

    return parts.isEmpty ? [element.outerHtml] : parts;
  }

  /// Extract all elements from HTML body
  static List<html_dom.Element> _extractElements(html_dom.Element body) {
    final elements = <html_dom.Element>[];
    
    for (final node in body.nodes) {
      if (node is html_dom.Element) {
        if (node.localName == 'p' || node.localName == 'div') {
          elements.add(node);
        } else if (node.children.isNotEmpty) {
          // Recursively extract from nested elements
          elements.addAll(_extractElements(node));
        }
      }
    }

    return elements;
  }

  /// Create a new element with the same tag but different text
  static html_dom.Element _createElementWithText(
    html_dom.Element original,
    String text,
  ) {
    final newElement = html_dom.Element.tag(original.localName!);
    original.attributes.forEach((key, value) {
      newElement.attributes[key] = value;
    });
    newElement.text = text;
    return newElement;
  }

  /// Wrap content in a basic HTML structure
  static String _wrapContent(String content) {
    if (content.trim().isEmpty) {
      return '<p>No content available.</p>';
    }
    if (content.trim().startsWith('<')) {
      return content;
    }
    return '<p>$content</p>';
  }
}

