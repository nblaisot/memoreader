import 'package:flutter/material.dart';
import 'package:epubx/epubx.dart';
import '../models/chapter.dart';
import 'dynamic_pagination_helper.dart';

/// Helper functions for reader screen operations
/// 
/// This file contains utility functions for:
/// - Parsing EPUB chapters
/// - Splitting HTML content into pages
/// - Calculating reading progress
class ReaderHelpers {
  /// Parse chapters from an EPUB book
  /// 
  /// Extracts chapters from the EPUB and converts them to our Chapter model.
  /// Handles errors gracefully by skipping corrupted chapters.
  static List<Chapter> parseChapters(EpubBook epubBook) {
    final chapters = <Chapter>[];

    try {
      final epubChapters = epubBook.Chapters;
      if (epubChapters == null || epubChapters.isEmpty) {
        return chapters;
      }

      for (int i = 0; i < epubChapters.length; i++) {
        try {
          final epubChapter = epubChapters[i];
          final title = epubChapter.Title?.isNotEmpty == true
              ? epubChapter.Title!
              : 'Chapter ${i + 1}';
          final htmlContent = epubChapter.HtmlContent ?? '';

          if (htmlContent.isNotEmpty) {
            chapters.add(Chapter(
              index: i,
              title: title,
              htmlContent: htmlContent,
            ));
          }
        } catch (e) {
          // Skip corrupted chapters
          debugPrint('Error parsing chapter $i: $e');
        }
      }
    } catch (e) {
      debugPrint('Error parsing chapters: $e');
    }

    return chapters.isEmpty ? [] : chapters;
  }

  /// Split HTML content into pages using TextPainter for accurate height measurement
  /// 
  /// This method uses Flutter's TextPainter to measure actual rendered text height,
  /// providing much more accurate pagination than character-based estimates.
  static Future<List<String>> splitIntoPages(
    BuildContext context,
    String htmlContent, {
    required double fontSize,
    double lineHeight = 1.6,
  }) async {
    if (htmlContent.isEmpty) {
      return ['<p>No content available.</p>'];
    }

    try {
      // Get screen dimensions
      final mediaQuery = MediaQuery.of(context);
      
      // Account for margins: 10px top + 10px bottom + safe area + footer (when visible ~60px)
      final topMargin = 10.0;
      final bottomMargin = 10.0;
      final footerHeight = 60.0; // Approximate footer height when visible
      final safeAreaTop = mediaQuery.padding.top;
      final safeAreaBottom = mediaQuery.padding.bottom;
      
      // Available height for text content (exact calculation)
      final availableHeight = mediaQuery.size.height -
          safeAreaTop -
          safeAreaBottom -
          topMargin -
          bottomMargin -
          footerHeight;
      
      // Available width for text content (with horizontal padding of 16px on each side)
      final horizontalPadding = 32.0; // 16px on each side
      final availableWidth = mediaQuery.size.width - horizontalPadding;

      // Use DynamicPaginationHelper for dynamic measurement of rendered height
      return await DynamicPaginationHelper.splitIntoPages(
        context: context,
        htmlContent: htmlContent,
        fontSize: fontSize,
        lineHeight: lineHeight,
        availableHeight: availableHeight,
        availableWidth: availableWidth,
      );
    } catch (e) {
      debugPrint('Error splitting pages: $e');
      // Fallback to wrapping entire content
      return [htmlContent.trim().isEmpty ? '<p>No content available.</p>' : htmlContent];
    }
  }

  /// Extract HTML blocks (paragraphs and divs) preserving structure
  static List<String> _extractHtmlBlocks(String htmlContent) {
    final blocks = <String>[];
    
    // Find all paragraphs
    final paragraphRegex = RegExp(r'<p[^>]*>.*?</p>', dotAll: true);
    paragraphRegex.allMatches(htmlContent).forEach((match) {
      blocks.add(match.group(0)!);
    });

    // Find divs that aren't already captured in paragraphs
    final divRegex = RegExp(r'<div[^>]*>.*?</div>', dotAll: true);
    divRegex.allMatches(htmlContent).forEach((match) {
      final divContent = match.group(0)!;
      // Only add if not already part of a paragraph
      if (!blocks.any((block) => block.contains(divContent) && block.length > divContent.length)) {
        blocks.add(divContent);
      }
    });

    return blocks;
  }

  /// Strip HTML tags to get plain text for length estimation
  static String _stripHtmlTags(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Wrap page content in a basic HTML structure if needed
  static String _wrapPage(String content) {
    if (content.trim().isEmpty) {
      return '<p>No content available.</p>';
    }
    // If content already has HTML tags, return as is
    if (content.trim().startsWith('<')) {
      return content;
    }
    // Otherwise wrap in paragraph
    return '<p>$content</p>';
  }

  /// Split a large block (paragraph/div) into smaller parts that fit in a page
  static List<String> _splitLargeBlock(
    String block,
    double availableHeight,
    double lineHeightInPixels,
    int charsPerLine,
  ) {
    final parts = <String>[];
    final linesPerPage = (availableHeight / lineHeightInPixels).floor();
    final charsPerPage = charsPerLine * linesPerPage;
    
    // Strip HTML to get text content for positioning
    final blockText = _stripHtmlTags(block);
    
    // Try to split at sentence boundaries
    // Use String.split with pattern to split on sentence endings
    final sentenceEndPattern = r'[.!?。！？]\s*';
    final sentenceEndRegex = RegExp(sentenceEndPattern);
    final partsBySentence = blockText.split(sentenceEndPattern);
    
    String currentPart = '';
    int currentChars = 0;
    
    // Reconstruct sentences with their endings
    final matches = sentenceEndRegex.allMatches(blockText);
    final sentenceEndings = matches.map((m) => m.group(0) ?? '').toList();
    
    for (int i = 0; i < partsBySentence.length; i++) {
      final sentence = partsBySentence[i];
      final ending = i < sentenceEndings.length ? sentenceEndings[i] : '';
      final fullSentence = sentence + ending;
      final sentenceLength = fullSentence.length;
      
      if (currentChars + sentenceLength > charsPerPage && currentPart.isNotEmpty) {
        // Current part is full, save it
        parts.add(_reconstructBlockWithText(block, currentPart));
        currentPart = fullSentence;
        currentChars = sentenceLength;
      } else {
        currentPart += fullSentence;
        currentChars += sentenceLength;
      }
    }
    
    // Add remaining part
    if (currentPart.isNotEmpty) {
      parts.add(_reconstructBlockWithText(block, currentPart));
    }
    
    // Fallback: if splitting by sentences didn't work, split by characters
    if (parts.isEmpty || parts.length == 1 && parts[0].length > charsPerPage * 1.5) {
      return _splitByCharacterLimit(block, charsPerPage);
    }
    
    return parts;
  }
  
  /// Reconstruct HTML block with new text content
  /// This preserves the HTML structure (tags) while replacing the text
  static String _reconstructBlockWithText(String originalBlock, String newText) {
    // Extract opening and closing tags
    final tagMatch = RegExp(r'<([^>]+)>').firstMatch(originalBlock);
    final closingTagMatch = RegExp(r'</[^>]+>').allMatches(originalBlock).lastOrNull;
    
    if (tagMatch != null && closingTagMatch != null) {
      final openingTag = tagMatch.group(0)!;
      final closingTag = closingTagMatch.group(0)!;
      return '$openingTag$newText$closingTag';
    }
    
    // Fallback: wrap in paragraph
    return '<p>$newText</p>';
  }
  
  /// Split block by character limit as fallback
  static List<String> _splitByCharacterLimit(String block, int charsPerPage) {
    final parts = <String>[];
    final blockText = _stripHtmlTags(block);
    
    int start = 0;
    while (start < blockText.length) {
      final end = (start + charsPerPage).clamp(0, blockText.length);
      parts.add(_reconstructBlockWithText(block, blockText.substring(start, end)));
      start = end;
      if (start >= blockText.length) break;
    }
    
    return parts.isEmpty ? [block] : parts;
  }

  /// Split raw HTML when no structure is found
  static List<String> _splitRawHtml(
    String htmlContent,
    double availableHeight,
    double lineHeightInPixels,
    int charsPerLine,
  ) {
    final pages = <String>[];
    final linesPerPage = (availableHeight / lineHeightInPixels).floor();
    final charsPerPage = charsPerLine * linesPerPage;

    // Try to split at sentence boundaries when possible
    final sentenceEndRegex = RegExp(r'[.!?。！？]\s*');
    int start = 0;

    while (start < htmlContent.length) {
      final remaining = htmlContent.length - start;
      
      if (remaining <= charsPerPage) {
        // Last chunk
        pages.add(_wrapPage(htmlContent.substring(start)));
        break;
      }

      // Find the end position
      int end = start + charsPerPage;
      
      // Try to find a sentence end near the target position
      final searchStart = (end - charsPerPage * 0.3).round(); // Search in last 30% of chunk
      final searchEnd = (end + charsPerPage * 0.2).round().clamp(0, htmlContent.length);
      
      final sentenceMatch = sentenceEndRegex.firstMatch(
        htmlContent.substring(searchStart, searchEnd),
      );
      
      if (sentenceMatch != null) {
        end = searchStart + sentenceMatch.end;
      }

      pages.add(_wrapPage(htmlContent.substring(start, end)));
      start = end;
    }

    return pages.isEmpty ? [_wrapPage(htmlContent)] : pages;
  }

  /// Calculate overall reading progress
  /// 
  /// Returns a value between 0.0 and 1.0 representing how much of the book
  /// has been read based on chapters and pages within chapters.
  static double calculateOverallProgress({
    required int currentChapterIndex,
    required int currentPageInChapter,
    required int totalChapters,
    required int pagesInCurrentChapter,
  }) {
    if (totalChapters == 0 || pagesInCurrentChapter == 0) return 0.0;

    // Calculate progress based on chapters and pages
    // Approximate: each chapter contributes equally, and within a chapter progress is based on pages
    final chaptersRead = currentChapterIndex.toDouble();
    final currentChapterProgress =
        (currentPageInChapter + 1) / pagesInCurrentChapter;

    final totalChaptersDouble = totalChapters.toDouble();
    final overallProgress = (chaptersRead + currentChapterProgress) / totalChaptersDouble;

    return overallProgress.clamp(0.0, 1.0);
  }
}

