import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../utils/text_tokenizer.dart';
import 'document_model.dart';

/// Line-metrics-based pagination engine that fills pages based on line heights
/// rather than word-by-word. This approach is more efficient and avoids
/// overflow issues by using Flutter's native TextPainter line metrics.
class LineMetricsPaginationEngine {
  LineMetricsPaginationEngine({
    required List<DocumentBlock> blocks,
    required TextStyle baseTextStyle,
    required double maxWidth,
    required double maxHeight,
    required TextHeightBehavior textHeightBehavior,
    required TextScaler textScaler,
  })  : _blocks = blocks,
        _baseTextStyle = baseTextStyle,
        _maxWidth = maxWidth,
        _originalMaxHeight = maxHeight,
        _maxHeight = maxHeight,
        _textHeightBehavior = textHeightBehavior,
        _textScaler = textScaler {
    _buildPages();
  }

  static const double _minBreakPointMargin = 24.0;
  static const double _maxBreakPointMargin = 80.0;
  static const double _minPageBottomMargin = 48.0;
  static const double _maxBottomMarginFraction = 0.18;

  final List<DocumentBlock> _blocks;
  final TextStyle _baseTextStyle;
  final double _maxWidth;
  final double _originalMaxHeight;  // Store original for page bottom calculations
  final double _maxHeight;  // Effective max height (same as original for now)
  final TextHeightBehavior _textHeightBehavior;
  final TextScaler _textScaler;

  late final List<PageContent> _pages;
  int _totalCharacters = 0;

  int get totalPages => _pages.length;
  int get totalCharacters => _totalCharacters;

  bool matches({
    required List<DocumentBlock> blocks,
    required TextStyle baseStyle,
    required double maxWidth,
    required double maxHeight,
    required TextHeightBehavior textHeightBehavior,
    required TextScaler textScaler,
  }) {
    return identical(_blocks, blocks) &&
        (_baseTextStyle.fontSize ?? 16) == (baseStyle.fontSize ?? 16) &&
        (_baseTextStyle.height ?? 1.6) == (baseStyle.height ?? 1.6) &&
        _baseTextStyle.fontFamily == baseStyle.fontFamily &&
        (_maxWidth - maxWidth).abs() < 0.5 &&
        (_originalMaxHeight - maxHeight).abs() < 0.5 &&
        _textHeightBehavior.applyHeightToFirstAscent ==
            textHeightBehavior.applyHeightToFirstAscent &&
        _textHeightBehavior.applyHeightToLastDescent ==
            textHeightBehavior.applyHeightToLastDescent &&
        _textScaler == textScaler;
  }

  /// Get a page by index
  PageContent? getPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pages.length) {
      return null;
    }
    return _pages[pageIndex];
  }

  /// Find the page index that contains the given character index
  int findPageByCharacterIndex(int characterIndex) {
    if (_pages.isEmpty || characterIndex < 0) return 0;
    
    for (int i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (characterIndex >= page.startCharIndex &&
          characterIndex <= page.endCharIndex) {
        return i;
      }
    }
    
    // If not found, return last page
    return _pages.length - 1;
  }

  /// Find the previous page index from current page
  int? findPreviousPage(int currentPageIndex) {
    if (currentPageIndex <= 0) return null;
    return currentPageIndex - 1;
  }

  /// Find the next page index from current page
  int? findNextPage(int currentPageIndex) {
    if (currentPageIndex >= _pages.length - 1) return null;
    return currentPageIndex + 1;
  }

  /// Find the first page for a given chapter
  int? findPageForChapter(int chapterIndex) {
    for (int i = 0; i < _pages.length; i++) {
      if (_pages[i].chapterIndex == chapterIndex) {
        return i;
      }
    }
    return null;
  }

  void _buildPages() {
    final pages = <PageContent>[];
    int globalCharacterIndex = 0;
    int globalWordIndex = 0;

    for (int blockIndex = 0; blockIndex < _blocks.length; blockIndex++) {
      final block = _blocks[blockIndex];

      if (block is TextDocumentBlock) {
        final textPages = _paginateTextBlock(
          block,
          globalCharacterIndex,
          globalWordIndex,
          pages.isEmpty,
        );

        for (final textPage in textPages) {
          pages.add(textPage);
          globalCharacterIndex = textPage.endCharIndex + 1;
        }

        if (textPages.isNotEmpty) {
          final lastPage = textPages.last;
          if (lastPage.endWordIndex >= lastPage.startWordIndex) {
            globalWordIndex = lastPage.endWordIndex + 1;
          }
        }
      } else if (block is ImageDocumentBlock) {
        final imagePage = _createImagePage(
          block,
          globalCharacterIndex,
          globalWordIndex,
          pages.isEmpty,
        );

        if (imagePage != null) {
          pages.add(imagePage);
          globalCharacterIndex = imagePage.endCharIndex + 1;
        }
      }
    }

    _pages = pages;
    _totalCharacters = globalCharacterIndex;
  }

  List<PageContent> _paginateTextBlock(
    TextDocumentBlock block,
    int startCharIndex,
    int startWordIndex,
    bool isFirstBlock,
  ) {
    final pages = <PageContent>[];
    final text = block.text;

    if (text.isEmpty) {
      return pages;
    }

    final tokenSpans = tokenizeWithSpans(text);

    final textStyle = _baseTextStyle.copyWith(
      fontSize: (_baseTextStyle.fontSize ?? 16) * block.fontScale,
      fontWeight: block.fontWeight,
      fontStyle: block.fontStyle,
    );

    // Create TextPainter to get line metrics
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textAlign: block.textAlign,
      textDirection: TextDirection.ltr,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
    );
    textPainter.layout(maxWidth: _maxWidth);

    final lines = textPainter.computeLineMetrics();
    if (lines.isEmpty) {
      return pages;
    }

    final spacingBefore = isFirstBlock ? 0.0 : block.spacingBefore;
    final spacingAfter = block.spacingAfter;

    final pageBottomMargin = _computePageBottomMargin(
      textPainter.preferredLineHeight,
      spacingAfter,
    );

    // Match cosmos_epub approach: track cumulative height and use safety margins
    // Use effective max height with safety margin applied
    final effectiveMaxHeight = _originalMaxHeight - pageBottomMargin;
    double currentPageHeight = spacingBefore;
    int currentPageStartCharIndex = startCharIndex;
    int currentPageStartTextIndex = 0;
    int currentPageStartTokenIndex = 0;

    int findTokenIndexAfterOffset(int offset, int startIndex) {
      var index = startIndex;
      while (index < tokenSpans.length && tokenSpans[index].end <= offset) {
        index++;
      }
      return index;
    }

    int safeBreakOffsetForTokenPointer(int tokenPointer) {
      if (tokenPointer <= 0) {
        return currentPageStartTextIndex;
      }
      if (tokenPointer >= tokenSpans.length) {
        return text.length;
      }
      return tokenSpans[tokenPointer].start;
    }

    for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex];
      final lineHeight = line.height;
      final breakPointMargin = _computeBreakPointMargin(lineHeight);
      final left = line.left;
      final top = line.baseline - line.ascent;
      
      // Calculate where this line starts in the text
      final lineStartOffset = textPainter.getPositionForOffset(
        Offset(0, top),
      ).offset;

      // Calculate cumulative height if we add this line
      final isLastLine = lineIndex == lines.length - 1;
      final effectiveSpacingAfter = isLastLine ? spacingAfter : 0.0;
      final totalHeightWithLine = currentPageHeight + lineHeight + effectiveSpacingAfter;

      // Check if adding this line would exceed effective max height
      if (totalHeightWithLine > effectiveMaxHeight && currentPageStartTextIndex < lineStartOffset) {
        // Break BEFORE the line that would overflow (matching cosmos_epub)
        // Find break point by subtracting breakPointMargin from line top
        final breakPointTop = (top - breakPointMargin).clamp(0.0, double.infinity);
        final breakPointOffset = textPainter.getPositionForOffset(Offset(left, breakPointTop)).offset;

        final targetBreakOffset = breakPointOffset > currentPageStartTextIndex
            ? breakPointOffset
            : lineStartOffset;

        var pageEndTokenPointerExclusive = findTokenIndexAfterOffset(
          targetBreakOffset,
          currentPageStartTokenIndex,
        );
        var safeBreakOffset =
            safeBreakOffsetForTokenPointer(pageEndTokenPointerExclusive);

        if (safeBreakOffset <= currentPageStartTextIndex &&
            lineStartOffset > currentPageStartTextIndex) {
          pageEndTokenPointerExclusive = findTokenIndexAfterOffset(
            lineStartOffset,
            currentPageStartTokenIndex,
          );
          safeBreakOffset =
              safeBreakOffsetForTokenPointer(pageEndTokenPointerExclusive);
        }

        if (safeBreakOffset <= currentPageStartTextIndex &&
            currentPageStartTokenIndex < tokenSpans.length) {
          final forcedPointer = currentPageStartTokenIndex + 1;
          pageEndTokenPointerExclusive = forcedPointer < tokenSpans.length
              ? forcedPointer
              : tokenSpans.length;
          if (pageEndTokenPointerExclusive > 0) {
            final previousToken =
                tokenSpans[pageEndTokenPointerExclusive - 1];
            safeBreakOffset = previousToken.end;
          } else {
            safeBreakOffset = text.length;
          }
        }

        if (safeBreakOffset > currentPageStartTextIndex) {
          final fitResult = _shrinkToFit(
            text: text,
            startOffset: currentPageStartTextIndex,
            endOffset: safeBreakOffset,
            startTokenPointer: currentPageStartTokenIndex,
            endTokenPointerExclusive: pageEndTokenPointerExclusive,
            spacingBefore: currentPageStartTextIndex == 0 ? spacingBefore : 0.0,
            spacingAfter: 0.0,
            textStyle: textStyle,
            textAlign: block.textAlign,
            availableHeight: effectiveMaxHeight,
            tokenSpans: tokenSpans,
          );

          if (fitResult == null || fitResult.text.isEmpty) {
            continue;
          }

          final pageStartTokenPointer = currentPageStartTokenIndex;
          final tokensInPage =
              fitResult.endTokenPointerExclusive - pageStartTokenPointer;
          final startWordPointer = startWordIndex + pageStartTokenPointer;
          final endWordPointer = tokensInPage > 0
              ? startWordPointer + tokensInPage - 1
              : startWordPointer - 1;

          final page = _createTextPage(
            fitResult.text,
            textStyle,
            block.textAlign,
            block.chapterIndex,
            currentPageStartCharIndex,
            currentPageStartCharIndex + fitResult.text.length - 1,
            startWordPointer,
            endWordPointer,
            currentPageStartTextIndex == 0 ? spacingBefore : 0.0,
            0.0,
          );
          pages.add(page);

          // Start new page
          currentPageStartCharIndex += fitResult.text.length;
          currentPageStartTextIndex = fitResult.endOffset;
          currentPageStartTokenIndex = fitResult.endTokenPointerExclusive;
          currentPageHeight = 0.0;
        }
      }

      // Add line height to current page
      currentPageHeight += lineHeight;

      // If this is the last line, finalize the page
      if (isLastLine) {
        final fitResult = _shrinkToFit(
          text: text,
          startOffset: currentPageStartTextIndex,
          endOffset: text.length,
          startTokenPointer: currentPageStartTokenIndex,
          endTokenPointerExclusive: tokenSpans.length,
          spacingBefore: currentPageStartTextIndex == 0 ? spacingBefore : 0.0,
          spacingAfter: spacingAfter,
          textStyle: textStyle,
          textAlign: block.textAlign,
          availableHeight: effectiveMaxHeight,
          tokenSpans: tokenSpans,
        );

        if (fitResult != null && fitResult.text.isNotEmpty) {
          final pageStartTokenPointer = currentPageStartTokenIndex;
          final tokensInPage =
              fitResult.endTokenPointerExclusive - pageStartTokenPointer;
          final startWordPointer = startWordIndex + pageStartTokenPointer;
          final endWordPointer = tokensInPage > 0
              ? startWordPointer + tokensInPage - 1
              : startWordPointer - 1;

          pages.add(_createTextPage(
            fitResult.text,
            textStyle,
            block.textAlign,
            block.chapterIndex,
            currentPageStartCharIndex,
            currentPageStartCharIndex + fitResult.text.length - 1,
            startWordPointer,
            endWordPointer,
            currentPageStartTextIndex == 0 ? spacingBefore : 0.0,
            spacingAfter,
          ));
        }
      }
    }

    return pages;
  }

  double _computeBreakPointMargin(double lineHeight) {
    final target = lineHeight * 0.75;
    return target.clamp(_minBreakPointMargin, _maxBreakPointMargin);
  }

  double _computePageBottomMargin(double lineHeight, double spacingAfter) {
    final dynamicMargin = lineHeight + spacingAfter;
    final upperBound = _originalMaxHeight * _maxBottomMarginFraction;
    final effectiveUpperBound = math.max(_minPageBottomMargin, upperBound);
    return dynamicMargin.clamp(_minPageBottomMargin, effectiveUpperBound);
  }

  _FitResult? _shrinkToFit({
    required String text,
    required int startOffset,
    required int endOffset,
    required int startTokenPointer,
    required int endTokenPointerExclusive,
    required double spacingBefore,
    required double spacingAfter,
    required TextStyle textStyle,
    required TextAlign textAlign,
    required double availableHeight,
    required List<TokenSpan> tokenSpans,
  }) {
    int currentEndOffset = endOffset;
    int currentEndTokenPointerExclusive = endTokenPointerExclusive;

    while (currentEndOffset > startOffset) {
      final pageText = text.substring(startOffset, currentEndOffset);
      if (_fitsWithinHeight(
        pageText: pageText,
        spacingBefore: spacingBefore,
        spacingAfter: spacingAfter,
        textStyle: textStyle,
        textAlign: textAlign,
        availableHeight: availableHeight,
      )) {
        return _FitResult(
          text: pageText,
          endOffset: currentEndOffset,
          endTokenPointerExclusive: currentEndTokenPointerExclusive,
        );
      }

      if (currentEndTokenPointerExclusive <= startTokenPointer) {
        break;
      }

      currentEndTokenPointerExclusive -= 1;
      currentEndOffset = currentEndTokenPointerExclusive > startTokenPointer
          ? tokenSpans[currentEndTokenPointerExclusive - 1].end
          : startOffset;
    }

    return null;
  }

  bool _fitsWithinHeight({
    required String pageText,
    required double spacingBefore,
    required double spacingAfter,
    required TextStyle textStyle,
    required TextAlign textAlign,
    required double availableHeight,
  }) {
    if (pageText.isEmpty) {
      return true;
    }

    final textPainter = TextPainter(
      text: TextSpan(text: pageText, style: textStyle),
      textAlign: textAlign,
      textDirection: TextDirection.ltr,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
    );
    textPainter.layout(maxWidth: _maxWidth);

    final lines = textPainter.computeLineMetrics();
    if (lines.isEmpty) {
      return true;
    }

    double totalHeight = spacingBefore;
    for (final line in lines) {
      totalHeight += line.height;
    }
    totalHeight += spacingAfter;

    final roundedHeight = totalHeight.ceilToDouble();
    return roundedHeight <= availableHeight;
  }

  PageContent? _createImagePage(
    ImageDocumentBlock block,
    int startCharIndex,
    int startWordIndex,
    bool isFirstBlock,
  ) {
    final spacingBefore = isFirstBlock ? 0.0 : block.spacingBefore;
    final spacingAfter = block.spacingAfter;

    // Calculate fitted image height
    final intrinsicWidth = block.intrinsicWidth ?? _maxWidth;
    final intrinsicHeight = block.intrinsicHeight ?? (_maxWidth * 0.6);
    
    double fittedHeight = intrinsicHeight;
    if (intrinsicWidth > 0 && intrinsicHeight > 0) {
      // Scale to fit width
      final scale = _maxWidth / intrinsicWidth;
      fittedHeight = intrinsicHeight * scale;
    }

    final availableHeight = _maxHeight - spacingBefore - spacingAfter;
    if (fittedHeight > availableHeight) {
      fittedHeight = availableHeight;
    }

    final totalHeight = spacingBefore + fittedHeight + spacingAfter;
    if (totalHeight > _maxHeight) {
      return null; // Image too large
    }

    final imageBlock = ImagePageBlock(
      bytes: block.bytes,
      height: fittedHeight,
      spacingBefore: spacingBefore,
      spacingAfter: spacingAfter,
    );

    return PageContent(
      blocks: [imageBlock],
      chapterIndex: block.chapterIndex,
      startWordIndex: startWordIndex,
      endWordIndex: startWordIndex,
      startCharIndex: startCharIndex,
      endCharIndex: startCharIndex,
    );
  }

  PageContent _createTextPage(
    String text,
    TextStyle style,
    TextAlign textAlign,
    int chapterIndex,
    int startCharIndex,
    int endCharIndex,
    int startWordIndex,
    int endWordIndex,
    double spacingBefore,
    double spacingAfter,
  ) {
    final textBlock = TextPageBlock(
      text: text,
      style: style,
      textAlign: textAlign,
      spacingBefore: spacingBefore,
      spacingAfter: spacingAfter,
    );

    return PageContent(
      blocks: [textBlock],
      chapterIndex: chapterIndex,
      startWordIndex: startWordIndex,
      endWordIndex: endWordIndex,
      startCharIndex: startCharIndex,
      endCharIndex: endCharIndex,
    );
  }
}

class _FitResult {
  const _FitResult({
    required this.text,
    required this.endOffset,
    required this.endTokenPointerExclusive,
  });

  final String text;
  final int endOffset;
  final int endTokenPointerExclusive;
}

