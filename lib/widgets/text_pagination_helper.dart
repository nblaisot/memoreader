import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

/// Helper class for accurate text pagination using TextPainter
/// 
/// This class uses Flutter's TextPainter to measure actual rendered text height,
/// providing much more accurate pagination than character-based estimates.
class TextPaginationHelper {
  /// Split HTML content into pages by measuring actual text height
  /// 
  /// Uses TextPainter to measure plain text height, then maps back to HTML
  /// to preserve structure while ensuring each page fits exactly in available space.
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
      // Parse HTML to extract structured content
      final document = html_parser.parse(htmlContent);
      if (document.body == null) {
        return [_wrapContent(htmlContent)];
      }

      // Extract plain text and create text style for measurement
      final textStyle = TextStyle(
        fontSize: fontSize,
        height: lineHeight,
      );

      // Get all paragraph and div elements
      final paragraphs = document.body!.querySelectorAll('p, div');
      
      // Adjust available height to account for margins
      // HTML rendering may have additional spacing, so we're conservative
      final margins = 20.0; // 10px top + 10px bottom
      final safetyMargin = 30.0; // Safety margin for HTML rendering differences (paragraph spacing, etc.)
      final adjustedAvailableHeight = math.max(availableHeight - margins - safetyMargin, 100.0);
      
      // If no structured content, try to extract text nodes
      if (paragraphs.isEmpty) {
        // Extract all text nodes
        final allText = document.body!.text ?? '';
        return _splitPlainTextToHtml(
          htmlContent,
          allText,
          textStyle,
          availableWidth,
          adjustedAvailableHeight,
        );
      }

      // Build pages by combining paragraphs and measuring height
      final pages = <String>[];
      String currentPage = '';
      double currentPageHeight = 0.0;

      for (final paragraph in paragraphs) {
        final paragraphText = paragraph.text ?? '';
        if (paragraphText.trim().isEmpty) {
          // Empty paragraph, add it to current page
          currentPage += paragraph.outerHtml;
          continue;
        }

        // Measure this paragraph's text height
        final paragraphHeight = _measureTextHeight(
          paragraphText,
          textStyle,
          availableWidth,
        );

        // If paragraph itself is too large, try to split it
        if (paragraphHeight > adjustedAvailableHeight) {
          // Save current page if it has content
          if (currentPage.isNotEmpty) {
            pages.add(_wrapContent(currentPage));
            currentPage = '';
            currentPageHeight = 0.0;
          }

          // Split the large paragraph
          final splitParts = _splitLargeParagraph(
            paragraph,
            textStyle,
            availableWidth,
            adjustedAvailableHeight,
          );

          for (final part in splitParts) {
            final partText = part.text ?? '';
            final partHeight = _measureTextHeight(partText, textStyle, availableWidth);

            if (currentPage.isNotEmpty && 
                currentPageHeight + partHeight > adjustedAvailableHeight) {
              pages.add(_wrapContent(currentPage));
              currentPage = '';
              currentPageHeight = 0.0;
            }

            currentPage += part.outerHtml;
            currentPageHeight += partHeight;
          }
        }
        // If adding this paragraph would exceed page height, start new page
        else if (currentPage.isNotEmpty && 
            currentPageHeight + paragraphHeight > adjustedAvailableHeight) {
          // Current page is full, save it
          pages.add(_wrapContent(currentPage));
          currentPage = paragraph.outerHtml;
          currentPageHeight = paragraphHeight;
        } else {
          // Add paragraph to current page
          currentPage += paragraph.outerHtml;
          currentPageHeight += paragraphHeight;
        }
      }

      // Add remaining content as last page
      if (currentPage.isNotEmpty) {
        pages.add(_wrapContent(currentPage));
      }

      // Handle any remaining text nodes that weren't in paragraphs
      final remainingText = document.body!.text ?? '';
      final paragraphsText = paragraphs.map((p) => p.text ?? '').join(' ');
      if (remainingText.trim().length > paragraphsText.trim().length) {
        // There's additional text not in paragraphs, add it as a separate page if needed
        // This is a fallback for edge cases
      }

      return pages.isEmpty ? [_wrapContent(htmlContent)] : pages;
    } catch (e) {
      debugPrint('Error splitting pages with TextPainter: $e');
      // Fallback: return entire content as one page
      return [_wrapContent(htmlContent)];
    }
  }

  /// Measure text height using TextPainter
  static double _measureTextHeight(
    String text,
    TextStyle textStyle,
    double maxWidth,
  ) {
    if (text.trim().isEmpty) return 0.0;
    
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    textPainter.layout(maxWidth: maxWidth);
    // Add small extra (8%) to account for HTML rendering differences 
    // (paragraph spacing, padding, etc. that TextPainter doesn't measure)
    return textPainter.size.height * 1.08;
  }

  /// Split a large paragraph into smaller parts that fit in available height
  static List<html_dom.Element> _splitLargeParagraph(
    html_dom.Element paragraph,
    TextStyle textStyle,
    double maxWidth,
    double maxHeight,
  ) {
    final parts = <html_dom.Element>[];
    final paragraphText = paragraph.text ?? '';
    
    if (paragraphText.trim().isEmpty) {
      return [paragraph];
    }

    // Try to split at sentence boundaries
    final sentences = paragraphText.split(RegExp(r'([.!?。！？]\s*)'));
    
    String currentPartText = '';
    double currentHeight = 0.0;

    for (int i = 0; i < sentences.length; i++) {
      final sentence = sentences[i];
      if (sentence.trim().isEmpty) continue;
      
      final sentenceHeight = _measureTextHeight(sentence, textStyle, maxWidth);

      if (currentPartText.isNotEmpty && 
          currentHeight + sentenceHeight > maxHeight) {
        // Current part is full, create element with this part
        final partElement = _createParagraphWithText(paragraph, currentPartText);
        parts.add(partElement);
        currentPartText = sentence;
        currentHeight = sentenceHeight;
      } else {
        currentPartText += sentence;
        currentHeight += sentenceHeight;
      }
    }

    // Add remaining part
    if (currentPartText.trim().isNotEmpty) {
      final partElement = _createParagraphWithText(paragraph, currentPartText);
      parts.add(partElement);
    }

    // Fallback: if splitting by sentences didn't work, split by character count
    if (parts.isEmpty) {
      // Estimate characters per page
      final charsPerLine = (maxWidth / (textStyle.fontSize! * 0.6)).round();
      final linesPerPage = (maxHeight / (textStyle.fontSize! * textStyle.height!)).floor();
      final charsPerPage = charsPerLine * linesPerPage;

      int start = 0;
      while (start < paragraphText.length) {
        final end = (start + charsPerPage).clamp(0, paragraphText.length);
        final partText = paragraphText.substring(start, end);
        final partElement = _createParagraphWithText(paragraph, partText);
        parts.add(partElement);
        start = end;
        if (start >= paragraphText.length) break;
      }
    }

    return parts.isEmpty ? [paragraph] : parts;
  }

  /// Create a new paragraph element with the same tag and attributes but different text
  static html_dom.Element _createParagraphWithText(
    html_dom.Element original,
    String text,
  ) {
    final newElement = html_dom.Element.tag(original.localName!);
    // Copy attributes
    original.attributes.forEach((key, value) {
      newElement.attributes[key] = value;
    });
    newElement.text = text;
    return newElement;
  }

  /// Split plain text and map back to HTML structure
  static List<String> _splitPlainTextToHtml(
    String originalHtml,
    String plainText,
    TextStyle textStyle,
    double maxWidth,
    double maxHeight,
  ) {
    final pages = <String>[];
    
    // Measure total height
    final totalHeight = _measureTextHeight(plainText, textStyle, maxWidth);
    
    if (totalHeight <= maxHeight) {
      return [_wrapContent(originalHtml)];
    }

    // Split text into pages using TextPainter
    int start = 0;
    while (start < plainText.length) {
      // Binary search to find the right amount of text that fits
      int low = start;
      int high = plainText.length;
      int bestEnd = start;

      while (low < high) {
        final mid = (low + high) ~/ 2;
        final testText = plainText.substring(start, mid);
        final testHeight = _measureTextHeight(testText, textStyle, maxWidth);

        if (testHeight <= maxHeight) {
          bestEnd = mid;
          low = mid + 1;
        } else {
          high = mid;
        }
      }

      // Try to find a sentence boundary near bestEnd
      final searchStart = (bestEnd - 100).clamp(start, plainText.length);
      final searchEnd = (bestEnd + 100).clamp(0, plainText.length);
      final searchText = plainText.substring(searchStart, searchEnd);
      
      final sentenceMatch = RegExp(r'[.!?。！？]\s*').allMatches(searchText).lastOrNull;
      int actualEnd = bestEnd;
      
      if (sentenceMatch != null && 
          searchStart + sentenceMatch.end <= plainText.length) {
        actualEnd = searchStart + sentenceMatch.end;
      }

      // Extract this page's content
      final pageText = plainText.substring(start, actualEnd);
      
      // Try to preserve HTML structure if possible
      // This is a simplified version - in practice, you'd want more sophisticated mapping
      pages.add(_wrapContent('<p>$pageText</p>'));
      
      start = actualEnd;
      if (start >= plainText.length) break;
    }

    return pages.isEmpty ? [_wrapContent(originalHtml)] : pages;
  }

  /// Wrap content in a basic HTML structure
  static String _wrapContent(String content) {
    if (content.trim().isEmpty) {
      return '<p>No content available.</p>';
    }
    // If content already has HTML tags, return as is
    if (content.trim().startsWith('<')) {
      return content;
    }
    return '<p>$content</p>';
  }
}
