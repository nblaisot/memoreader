import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../utils/text_tokenizer.dart';
import 'document_model.dart';
import 'pagination_cache.dart';

/// Hybrid pagination engine that combines lazy, on-demand pagination with
/// persisted caches per layout configuration.
///
/// The engine only materializes the current reading window (current, previous,
/// and next pages) when a book is opened or when layout changes occur. The
/// remaining pages are generated lazily in the background and saved to disk so
/// subsequent openings with the same layout can reuse the cached results.
class LineMetricsPaginationEngine extends ChangeNotifier {
  LineMetricsPaginationEngine._({
    required String bookId,
    required List<DocumentBlock> blocks,
    required TextStyle baseTextStyle,
    required double maxWidth,
    required double maxHeight,
    required TextHeightBehavior textHeightBehavior,
    required TextScaler textScaler,
    required PaginationCacheManager? cacheManager,
    required double viewportInsetBottom,
    required bool tracingEnabled,
  })  : _bookId = bookId,
        _blocks = blocks,
        _baseTextStyle = baseTextStyle,
        _maxWidth = maxWidth,
        _originalMaxHeight = maxHeight,
        _maxHeight = maxHeight,
        _textHeightBehavior = textHeightBehavior,
        _textScaler = textScaler,
        _cacheManager = cacheManager,
        _viewportInsetBottom = viewportInsetBottom,
        _tracingEnabled = tracingEnabled,
        _layoutKey = _computeLayoutKey(
          baseTextStyle: baseTextStyle,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          textHeightBehavior: textHeightBehavior,
          textScaler: textScaler,
          viewportInsetBottom: viewportInsetBottom,
        ) {
    _textStates = List<_TextBlockState?>.filled(_blocks.length, null);
    _imageConsumed = List<bool>.filled(_blocks.length, false);
  }

  static const double _minBreakPointMargin = 20.0;
  static const double _maxBreakPointMargin = 80.0;
  static const double _minPageBottomMargin = 20.0;
  static const double _maxBottomMarginFraction = 0.12;
  static const double _heightTolerance = 0.5;
  static const bool _defaultTracingFlag =
      bool.fromEnvironment('ENABLE_READER_PAGINATION_TRACE', defaultValue: false);

  final String _bookId;
  final List<DocumentBlock> _blocks;
  final TextStyle _baseTextStyle;
  final double _maxWidth;
  final double _originalMaxHeight;
  final double _maxHeight;
  final TextHeightBehavior _textHeightBehavior;
  final TextScaler _textScaler;
  final PaginationCacheManager? _cacheManager;
  final double _viewportInsetBottom;
  final bool _tracingEnabled;
  final String _layoutKey;

  late final List<_TextBlockState?> _textStates;
  late final List<bool> _imageConsumed;

  final List<PageContent> _pages = <PageContent>[];
  int _totalCharacters = 0;
  bool _isComplete = false;
  int? _finalPageCount;
  bool _isBackgroundPaginationRunning = false;
  PaginationCursorSnapshot? _cursor;
  Future<void>? _ongoingComputation;
  Future<void>? _ongoingSave;

  void _trace(String message) {
    if (!_tracingEnabled) return;
    debugPrint('[PaginationEngine] $message');
  }

  /// Creates a new engine. If a compatible cache is available it will be
  /// loaded to seed the lazy pagination process.
  static Future<LineMetricsPaginationEngine> create({
    required String bookId,
    required List<DocumentBlock> blocks,
    required TextStyle baseTextStyle,
    required double maxWidth,
    required double maxHeight,
    required TextHeightBehavior textHeightBehavior,
    required TextScaler textScaler,
    PaginationCacheManager? cacheManager,
    double viewportInsetBottom = 0.0,
    bool tracingEnabled = _defaultTracingFlag,
  }) async {
    final engine = LineMetricsPaginationEngine._(
      bookId: bookId,
      blocks: blocks,
      baseTextStyle: baseTextStyle,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      textHeightBehavior: textHeightBehavior,
      textScaler: textScaler,
      cacheManager: cacheManager,
      viewportInsetBottom: viewportInsetBottom,
      tracingEnabled: tracingEnabled,
    );

    if (cacheManager != null) {
      final cached = await cacheManager.load(bookId, engine._layoutKey);
      if (cached != null) {
        engine._restoreFromCache(cached);
      }
    }

    engine._cursor ??= PaginationCursorSnapshot(
      blockIndex: 0,
      globalCharIndex: 0,
      globalWordIndex: 0,
      textState: const TextCursorSnapshot(
        lineIndex: 0,
        textOffset: 0,
        tokenPointer: 0,
      ),
    );

    return engine;
  }

  static String _computeLayoutKey({
    required TextStyle baseTextStyle,
    required double maxWidth,
    required double maxHeight,
    required TextHeightBehavior textHeightBehavior,
    required TextScaler textScaler,
    required double viewportInsetBottom,
  }) {
    final buffer = StringBuffer()
      ..write('v3|')
      ..write(baseTextStyle.fontFamily ?? 'default')
      ..write('|')
      ..write(baseTextStyle.fontSize?.toStringAsFixed(2) ?? '16.0')
      ..write('|')
      ..write((baseTextStyle.height ?? 1.0).toStringAsFixed(2))
      ..write('|')
      ..write(maxWidth.toStringAsFixed(1))
      ..write('|')
      ..write(maxHeight.toStringAsFixed(1))
      ..write('|')
      ..write(textHeightBehavior.applyHeightToFirstAscent ? '1' : '0')
      ..write(textHeightBehavior.applyHeightToLastDescent ? '1' : '0')
      ..write('|')
      ..write(textScaler.hashCode)
      ..write('|')
      ..write(viewportInsetBottom.toStringAsFixed(1));
    return base64UrlEncode(buffer.toString().codeUnits);
  }

  void _restoreFromCache(PaginationCacheEntry cache) {}

  int? get totalPages => _finalPageCount;
  int get computedPageCount => _pages.length;
  int get totalCharacters => _totalCharacters;
  bool get isComplete => _isComplete;

  int get estimatedTotalPages {
    if (_finalPageCount != null) {
      return _finalPageCount!;
    }
    if (_cursor == null || _cursor!.blockIndex >= _blocks.length) {
      return _pages.length;
    }
    return math.max(_pages.length + 1, _pages.length);
  }

  PageContent? getPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pages.length) {
      return null;
    }
    return _pages[pageIndex];
  }

  bool hasNextPage(int currentPageIndex) {
    if (currentPageIndex < _pages.length - 1) {
      return true;
    }
    if (_isComplete) {
      return false;
    }
    return _cursor != null && _cursor!.blockIndex < _blocks.length;
  }

  bool hasPreviousPage(int currentPageIndex) {
    return currentPageIndex > 0;
  }

  int findPageByCharacterIndex(int characterIndex) {
    if (_pages.isEmpty || characterIndex < 0) {
      return 0;
    }
    for (int i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (characterIndex >= page.startCharIndex &&
          characterIndex <= page.endCharIndex) {
        return i;
      }
    }
    return _pages.length - 1;
  }

  int? findPageForChapter(int chapterIndex) {
    final index = _pages.indexWhere((page) => page.chapterIndex == chapterIndex);
    if (index != -1) {
      return index;
    }
    if (_isComplete) {
      return null;
    }
    while (!_isComplete) {
      final generated = _computeNextPage();
      if (generated == null) {
        break;
      }
    }
    final updatedIndex =
        _pages.indexWhere((page) => page.chapterIndex == chapterIndex);
    return updatedIndex == -1 ? null : updatedIndex;
  }

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

  Future<int> ensurePageForCharacter(int characterIndex,
      {int windowRadius = 1}) async {
    await _ensureCharacterInPages(characterIndex);
    final pageIndex = findPageByCharacterIndex(characterIndex);
    await ensureWindow(pageIndex, radius: windowRadius);
    return pageIndex;
  }

  Future<void> ensureWindow(int centerPage, {int radius = 1}) async {
    final targetPage = centerPage + radius;
    await _runSerially(() async {
      while (_pages.length <= targetPage && !_isComplete) {
        final generated = _computeNextPage();
        if (generated == null) {
          break;
        }
        await _persistCache();
        notifyListeners();
      }
    });
  }

  Future<void> _ensureCharacterInPages(int characterIndex) async {
    await _runSerially(() async {
      while (!_isComplete) {
        if (_pages.isNotEmpty &&
            _pages.last.endCharIndex >= characterIndex) {
          break;
        }
        final generated = _computeNextPage();
        if (generated == null) {
          break;
        }
        await _persistCache();
        notifyListeners();
      }
    });
  }

  Future<void> startBackgroundPagination() async {
    if (_isComplete || _isBackgroundPaginationRunning) {
      return;
    }
    _isBackgroundPaginationRunning = true;
    unawaited(Future<void>(() async {
      try {
        while (!_isComplete) {
          final generated = await _runSerially(() async {
            final page = _computeNextPage();
            if (page != null) {
              await _persistCache();
              notifyListeners();
            }
            return page;
          });
          if (generated == null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
      } finally {
        _isBackgroundPaginationRunning = false;
      }
    }));
  }

  Future<T?> _runSerially<T>(Future<T?> Function() action) {
    final previous = _ongoingComputation ?? Future<T?>.value();
    final completer = Completer<T?>();
    _ongoingComputation = previous.then((_) => action()).then((value) {
      completer.complete(value);
      return null;
    }).catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      return null;
    });
    return completer.future;
  }

  Future<void> _persistCache() async {
    if (_cacheManager == null) {
      return;
    }
    final cursorSnapshot = _cursor;
    final entry = PaginationCacheEntry(
      pages: _pages.map(_toCachedPage).toList(growable: false),
      isComplete: _isComplete,
      totalCharacters: _totalCharacters,
      cursor: _isComplete ? null : cursorSnapshot,
    );
    _ongoingSave = _cacheManager
        .save(_bookId, _layoutKey, entry)
        .catchError((_) => null);
    await _ongoingSave;
  }

  CachedPageData _toCachedPage(PageContent page) {
    final blocks = <CachedPageBlockData>[];
    for (final block in page.blocks) {
      if (block is TextPageBlock) {
        final style = block.baseStyle;
        blocks.add(CachedPageBlockData.text(
          text: block.text,
          spacingBefore: block.spacingBefore,
          spacingAfter: block.spacingAfter,
          textAlign: block.textAlign.index,
          fontSize: style.fontSize ?? _baseTextStyle.fontSize,
          height: style.height ?? _baseTextStyle.height,
          color: style.color?.value,
          fontWeight: style.fontWeight != null
              ? style.fontWeight!.index
              : _baseTextStyle.fontWeight?.index,
          fontStyle: style.fontStyle == FontStyle.italic ? 'italic' : 'normal',
          fontFamily: style.fontFamily ?? _baseTextStyle.fontFamily,
        ));
      } else if (block is ImagePageBlock) {
        blocks.add(CachedPageBlockData.image(
          spacingBefore: block.spacingBefore,
          spacingAfter: block.spacingAfter,
          imageHeight: block.height,
          imageBytes: block.bytes,
        ));
      }
    }
    return CachedPageData(
      chapterIndex: page.chapterIndex,
      startWordIndex: page.startWordIndex,
      endWordIndex: page.endWordIndex,
      startCharIndex: page.startCharIndex,
      endCharIndex: page.endCharIndex,
      blocks: blocks,
    );
  }

  PageContent? _computeNextPage() {
    if (_isComplete) {
      return null;
    }
    _cursor ??= PaginationCursorSnapshot(
        blockIndex: 0,
        globalCharIndex: 0,
        globalWordIndex: 0,
        textState: const TextCursorSnapshot(
          lineIndex: 0,
          textOffset: 0,
          tokenPointer: 0,
        ),
      );

    while (_cursor!.blockIndex < _blocks.length) {
      final block = _blocks[_cursor!.blockIndex];

      if (block is TextDocumentBlock) {
        final state = _obtainTextState(_cursor!.blockIndex);
        if (_cursor!.textState != null) {
          state.applyCursor(_cursor!.textState!);
          _cursor = PaginationCursorSnapshot(
            blockIndex: _cursor!.blockIndex,
            globalCharIndex: _cursor!.globalCharIndex,
            globalWordIndex: _cursor!.globalWordIndex,
            textState: null,
          );
        }

        if (state.isComplete) {
          _cursor = PaginationCursorSnapshot(
            blockIndex: _cursor!.blockIndex + 1,
            globalCharIndex: _cursor!.globalCharIndex,
            globalWordIndex: _cursor!.globalWordIndex,
            textState: null,
          );
          continue;
        }

        final result = _buildTextPage(
          state: state,
          blockIndex: _cursor!.blockIndex,
          globalCharIndex: _cursor!.globalCharIndex,
          globalWordIndex: _cursor!.globalWordIndex,
        );

        if (result == null) {
          state.markComplete();
          _cursor = PaginationCursorSnapshot(
            blockIndex: _cursor!.blockIndex + 1,
            globalCharIndex: _cursor!.globalCharIndex,
            globalWordIndex: _cursor!.globalWordIndex,
            textState: null,
          );
          continue;
        }

        _pages.add(result.page);
        _totalCharacters = result.page.endCharIndex + 1;

        if (result.tokensInPage > 0) {
          _cursor = PaginationCursorSnapshot(
            blockIndex: result.blockCompleted
                ? _cursor!.blockIndex + 1
                : _cursor!.blockIndex,
            globalCharIndex:
                _cursor!.globalCharIndex + result.charactersInPage,
            globalWordIndex:
                _cursor!.globalWordIndex + result.tokensInPage,
            textState: result.blockCompleted ? null : result.nextCursor,
          );
        } else {
          _cursor = PaginationCursorSnapshot(
            blockIndex: result.blockCompleted
                ? _cursor!.blockIndex + 1
                : _cursor!.blockIndex,
            globalCharIndex:
                _cursor!.globalCharIndex + result.charactersInPage,
            globalWordIndex: _cursor!.globalWordIndex,
            textState: result.blockCompleted ? null : result.nextCursor,
          );
        }

        if (result.blockCompleted) {
          state.markComplete();
        }

        return result.page;
      } else if (block is ImageDocumentBlock) {
        if (_imageConsumed[_cursor!.blockIndex]) {
          _cursor = PaginationCursorSnapshot(
            blockIndex: _cursor!.blockIndex + 1,
            globalCharIndex: _cursor!.globalCharIndex,
            globalWordIndex: _cursor!.globalWordIndex,
            textState: null,
          );
          continue;
        }

        final page = _createImagePage(
          block,
          _cursor!.globalCharIndex,
          _cursor!.globalWordIndex,
          _cursor!.blockIndex == 0,
        );

        _imageConsumed[_cursor!.blockIndex] = true;
        _cursor = PaginationCursorSnapshot(
          blockIndex: _cursor!.blockIndex + 1,
          globalCharIndex: _cursor!.globalCharIndex + 1,
          globalWordIndex: _cursor!.globalWordIndex,
          textState: null,
        );

        if (page != null) {
          _pages.add(page);
          _totalCharacters = page.endCharIndex + 1;
          return page;
        }
      } else {
        _cursor = PaginationCursorSnapshot(
          blockIndex: _cursor!.blockIndex + 1,
          globalCharIndex: _cursor!.globalCharIndex,
          globalWordIndex: _cursor!.globalWordIndex,
          textState: null,
        );
      }
    }

    _isComplete = true;
    _finalPageCount = _pages.length;
    return null;
  }

  _TextBlockState _obtainTextState(int blockIndex) {
    final existing = _textStates[blockIndex];
    if (existing != null) {
      return existing;
    }
    final block = _blocks[blockIndex] as TextDocumentBlock;
    final state = _TextBlockState(
      block: block,
      baseTextStyle: _baseTextStyle,
      maxWidth: _maxWidth,
      maxHeight: _maxHeight,
      originalMaxHeight: _originalMaxHeight,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
      computeBreakPointMargin: _computeBreakPointMargin,
      computePageBottomMargin: _computePageBottomMargin,
      trace: _trace,
      tracingEnabled: _tracingEnabled,
    );
    _textStates[blockIndex] = state;
    return state;
  }

  _TextPageResult? _buildTextPage({
    required _TextBlockState state,
    required int blockIndex,
    required int globalCharIndex,
    required int globalWordIndex,
  }) {
    return state.buildNextPage(
      globalCharIndex: globalCharIndex,
      globalWordIndex: globalWordIndex,
      isFirstBlock: blockIndex == 0,
    );
  }

  double _computeBreakPointMargin(double lineHeight) {
    final target = lineHeight * (lineHeight > 64 ? 0.5 : 0.6);
    return target.clamp(_minBreakPointMargin, _maxBreakPointMargin);
  }

  double _computePageBottomMargin(double lineHeight, double spacingAfter) {
    final insetInfluence = _viewportInsetBottom * 0.6;
    // Reduced multipliers for more conservative margins to allow better page filling
    final dynamicMargin = lineHeight * 0.3 + spacingAfter * 0.3 + insetInfluence;
    final minMargin = math.max(_minPageBottomMargin, _viewportInsetBottom * 0.5);
    final upperBound = (_originalMaxHeight + _viewportInsetBottom) *
        _maxBottomMarginFraction;
    final effectiveUpperBound = math.max(minMargin, upperBound);
    return dynamicMargin.clamp(minMargin, effectiveUpperBound);
  }

  PageContent? _createImagePage(
    ImageDocumentBlock block,
    int startCharIndex,
    int startWordIndex,
    bool isFirstBlock,
  ) {
    // Don't apply spacingBefore - images should flow with content
    final spacingBefore = 0.0;
    final spacingAfter = 0.0;

    final intrinsicWidth = block.intrinsicWidth ?? _maxWidth;
    final intrinsicHeight = block.intrinsicHeight ?? (_maxWidth * 0.6);

    double fittedHeight = intrinsicHeight;
    if (intrinsicWidth > 0 && intrinsicHeight > 0) {
      final scale = _maxWidth / intrinsicWidth;
      fittedHeight = intrinsicHeight * scale;
    }

    // Limit image height to 60% of page height to allow text before/after
    final maxImageHeight = _maxHeight * 0.6;
    if (fittedHeight > maxImageHeight) {
      fittedHeight = maxImageHeight;
    }

    final availableHeight = _maxHeight - spacingBefore - spacingAfter;
    if (availableHeight <= 0) {
      return null;
    }
    if (fittedHeight > availableHeight) {
      fittedHeight = availableHeight;
    }

    final totalHeight = spacingBefore + fittedHeight + spacingAfter;
    if (totalHeight > _maxHeight) {
      return null;
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
}

class _TextBlockState {
  _TextBlockState({
    required this.block,
    required TextStyle baseTextStyle,
    required double maxWidth,
    required double maxHeight,
    required double originalMaxHeight,
    required TextHeightBehavior textHeightBehavior,
    required TextScaler textScaler,
    required double Function(double lineHeight) computeBreakPointMargin,
    required double Function(double lineHeight, double spacingAfter)
        computePageBottomMargin,
    required void Function(String message) trace,
    required bool tracingEnabled,
  })  : _maxWidth = maxWidth,
        _maxHeight = maxHeight,
        _originalMaxHeight = originalMaxHeight,
        _textHeightBehavior = textHeightBehavior,
        _textScaler = textScaler,
        _computeBreakPointMargin = computeBreakPointMargin,
        _computePageBottomMargin = computePageBottomMargin,
        _trace = trace,
        _tracingEnabled = tracingEnabled {
    final resolvedBaseStyle = block.baseStyle.isPlain
        ? baseTextStyle
        : block.baseStyle.resolve(baseTextStyle);
    _baseStyle = resolvedBaseStyle;
    final resolved = _buildFullSpan(resolvedBaseStyle);
    textPainter = TextPainter(
      text: resolved.span,
      textAlign: block.textAlign,
      textDirection: TextDirection.ltr,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
    );
    if (resolved.placeholderDimensions.isNotEmpty) {
      textPainter.setPlaceholderDimensions(resolved.placeholderDimensions);
    }
    textPainter.layout(maxWidth: _maxWidth);

    lines = textPainter.computeLineMetrics();
    tokenSpans = tokenizeWithSpans(block.text);

    lineStartOffsets = List<int>.generate(lines.length, (index) {
      final line = lines[index];
      final top = line.baseline - line.ascent;
      return textPainter.getPositionForOffset(Offset(0, top)).offset;
    });

    pageBottomMargin = _computePageBottomMargin(
      textPainter.preferredLineHeight,
      block.spacingAfter,
    );
    // Use _maxHeight directly to match rendering constraint in PageContentView
    // pageBottomMargin is a visual margin, not a constraint reduction
    effectiveMaxHeight = _maxHeight;

    if (_tracingEnabled) {
      _trace(
        'init bottomMargin=${pageBottomMargin.toStringAsFixed(2)} '
        'effectiveMaxHeight=${effectiveMaxHeight.toStringAsFixed(2)} '
        'lineHeight=${textPainter.preferredLineHeight.toStringAsFixed(2)} '
        'spacingAfter=${block.spacingAfter.toStringAsFixed(2)}',
      );
    }
  }

  final TextDocumentBlock block;
  late final TextPainter textPainter;
  late final List<LineMetrics> lines;
  late final List<int> lineStartOffsets;
  late final List<TokenSpan> tokenSpans;
  late final TextStyle _baseStyle;
  final double _maxWidth;
  final double _maxHeight;
  final double _originalMaxHeight;
  final TextHeightBehavior _textHeightBehavior;
  final TextScaler _textScaler;
  final double Function(double lineHeight) _computeBreakPointMargin;
  final double Function(double lineHeight, double spacingAfter)
      _computePageBottomMargin;
  final void Function(String message) _trace;
  final bool _tracingEnabled;

  late final double pageBottomMargin;
  late final double effectiveMaxHeight;

  int currentLineIndex = 0;
  int currentTextOffset = 0;
  int currentTokenPointer = 0;
  bool _complete = false;

  bool get isComplete => _complete || currentLineIndex >= lines.length;

  void markComplete() {
    currentLineIndex = lines.length;
    currentTextOffset = block.text.length;
    currentTokenPointer = tokenSpans.length;
    _complete = true;
  }

  void applyCursor(TextCursorSnapshot cursor) {
    currentLineIndex = cursor.lineIndex;
    currentTextOffset = cursor.textOffset;
    currentTokenPointer = cursor.tokenPointer;
  }

  _TextPageResult? buildNextPage({
    required int globalCharIndex,
    required int globalWordIndex,
    required bool isFirstBlock,
  }) {
    if (block.text.isEmpty || isComplete) {
      markComplete();
      return null;
    }

    // No forced spacing - text should flow continuously
    final spacingBefore = 0.0;
    final pageStartOffset = currentTextOffset;
    final pageStartTokenIndex = currentTokenPointer;
    int currentTokenIndex = pageStartTokenIndex;

    // Build page by adding words one by one until overflow
    // Use word packing to optimize line filling
    while (currentTokenIndex < tokenSpans.length) {
      // Include tokens from pageStartTokenIndex to currentTokenIndex (inclusive)
      final nextEndOffset = tokenSpans[currentTokenIndex].end;
      
      final candidateText = block.text.substring(pageStartOffset, nextEndOffset);
      final isLastToken = currentTokenIndex == tokenSpans.length - 1;
      final spacingAfter = isLastToken ? block.spacingAfter : 0.0;
      
      // Get fragments to account for inline images
      final candidateFragments = block.sliceFragments(
        pageStartOffset,
        nextEndOffset,
        baseStyle: _baseStyle,
      );
      
      // Measure height with current candidate
      final currentHeight = _measureHeight(
        pageText: candidateText,
        fragments: candidateFragments,
        spacingBefore: spacingBefore,
        spacingAfter: spacingAfter,
      );
      
      // Check if it fits
      final safetyMargin = 2.0;
      if (currentHeight > effectiveMaxHeight - safetyMargin) {
        // Doesn't fit, but check if we can pack more words on existing lines
        // Try adding one more word to see if height increases
        if (currentTokenIndex + 1 < tokenSpans.length) {
          final nextTokenEnd = tokenSpans[currentTokenIndex + 1].end;
          final extendedText = block.text.substring(pageStartOffset, nextTokenEnd);
          final isExtendedLastToken = currentTokenIndex + 1 == tokenSpans.length - 1;
          final extendedSpacingAfter = isExtendedLastToken ? block.spacingAfter : 0.0;
          final extendedFragments = block.sliceFragments(
            pageStartOffset,
            nextTokenEnd,
            baseStyle: _baseStyle,
          );
          final extendedHeight = _measureHeight(
            pageText: extendedText,
            fragments: extendedFragments,
            spacingBefore: spacingBefore,
            spacingAfter: extendedSpacingAfter,
          );
          
          // If height didn't increase (within tolerance), word fits on existing line
          if ((extendedHeight - currentHeight).abs() < 0.5) {
            // Height stayed same - word fits on existing line, keep it
            currentTokenIndex++;
            continue;
          }
          
          // Height increased - check if it still fits
          if (extendedHeight <= effectiveMaxHeight - safetyMargin) {
            // New line created but still fits
            currentTokenIndex++;
            continue;
          }
        }
        // Can't fit more, stop
        break;
      }
      
      // It fits, move to next token
      currentTokenIndex++;
    }

    // Build page with the words that fit
    if (currentTokenIndex > pageStartTokenIndex) {
      // After loop, currentTokenIndex points to first token that doesn't fit
      // So we include tokens from pageStartTokenIndex to currentTokenIndex - 1
      final pageEndOffset = currentTokenIndex > 0 && currentTokenIndex <= tokenSpans.length
          ? tokenSpans[currentTokenIndex - 1].end
          : block.text.length;

      final pageText = block.text.substring(pageStartOffset, pageEndOffset);
      final tokensInPage = currentTokenIndex - pageStartTokenIndex;
      final isLastToken = currentTokenIndex >= tokenSpans.length;
      final spacingAfter = isLastToken ? block.spacingAfter : 0.0;

      final fragments = block.sliceFragments(
        pageStartOffset,
        pageEndOffset,
        baseStyle: _baseStyle,
      );

      final startWordPointer = globalWordIndex;
      final endWordPointer = tokensInPage > 0
          ? startWordPointer + tokensInPage - 1
          : startWordPointer - 1;

      final page = PageContent(
        blocks: [
          TextPageBlock(
            text: pageText,
            fragments: fragments,
            textAlign: block.textAlign,
            baseStyle: _baseStyle,
            spacingBefore: spacingBefore,
            spacingAfter: spacingAfter,
            lineHeight: block.lineHeight,
          ),
        ],
        chapterIndex: block.chapterIndex,
        startWordIndex: startWordPointer,
        endWordIndex: endWordPointer,
        startCharIndex: globalCharIndex,
        endCharIndex: globalCharIndex + pageText.length - 1,
      );

      // Update state
      final nextTokenPointer = currentTokenIndex;
      final nextOffset = pageEndOffset;
      final nextLineIndex = _findLineIndexForOffset(nextOffset);

      currentLineIndex = nextLineIndex;
      currentTextOffset = nextOffset;
      currentTokenPointer = nextTokenPointer;

      final blockCompleted = nextOffset >= block.text.length;
      if (blockCompleted) {
        markComplete();
      }

      if (_tracingEnabled) {
        final pageHeight = _measureHeight(
          pageText: pageText,
          fragments: fragments,
          spacingBefore: spacingBefore,
          spacingAfter: spacingAfter,
        );
        _trace(
          'page built height=${pageHeight.toStringAsFixed(2)} '
          'tokens=$tokensInPage chars=${pageText.length} '
          'breakOffset=$nextOffset',
        );
      }

      final nextCursor = blockCompleted
          ? null
          : TextCursorSnapshot(
              lineIndex: currentLineIndex,
              textOffset: currentTextOffset,
              tokenPointer: currentTokenPointer,
            );

      return _TextPageResult(
        page: page,
        charactersInPage: pageText.length,
        tokensInPage: tokensInPage,
        blockCompleted: blockCompleted,
        nextCursor: nextCursor,
      );
    }

    // Edge case: no words fit (shouldn't happen, but handle it)
    // If even one word doesn't fit, we still need to place it
    if (pageStartTokenIndex < tokenSpans.length) {
      final singleToken = tokenSpans[pageStartTokenIndex];
      final pageText = block.text.substring(pageStartOffset, singleToken.end);
      final isLastToken = pageStartTokenIndex == tokenSpans.length - 1;
      final spacingAfter = isLastToken ? block.spacingAfter : 0.0;

      final fragments = block.sliceFragments(
        pageStartOffset,
        singleToken.end,
        baseStyle: _baseStyle,
      );

      final page = PageContent(
        blocks: [
          TextPageBlock(
            text: pageText,
            fragments: fragments,
            textAlign: block.textAlign,
            baseStyle: _baseStyle,
            spacingBefore: spacingBefore,
            spacingAfter: spacingAfter,
            lineHeight: block.lineHeight,
          ),
        ],
        chapterIndex: block.chapterIndex,
        startWordIndex: globalWordIndex,
        endWordIndex: globalWordIndex,
        startCharIndex: globalCharIndex,
        endCharIndex: globalCharIndex + pageText.length - 1,
      );

      final nextTokenPointer = pageStartTokenIndex + 1;
      final nextOffset = singleToken.end;
      final nextLineIndex = _findLineIndexForOffset(nextOffset);

      currentLineIndex = nextLineIndex;
      currentTextOffset = nextOffset;
      currentTokenPointer = nextTokenPointer;

      final blockCompleted = nextOffset >= block.text.length;
      if (blockCompleted) {
        markComplete();
      }

      final nextCursor = blockCompleted
          ? null
          : TextCursorSnapshot(
              lineIndex: currentLineIndex,
              textOffset: currentTextOffset,
              tokenPointer: currentTokenPointer,
            );

      return _TextPageResult(
        page: page,
        charactersInPage: pageText.length,
        tokensInPage: 1,
        blockCompleted: blockCompleted,
        nextCursor: nextCursor,
      );
    }

    markComplete();
    return null;
  }

  _TextPageResult? buildPreviousPage({
    required int globalCharIndex,
    required int globalWordIndex,
    required bool isLastBlock,
  }) {
    if (block.text.isEmpty || currentTokenPointer <= 0) {
      return null;
    }

    // No forced spacing - text should flow continuously
    final spacingBefore = 0.0;
    final pageEndOffset = currentTextOffset;
    final pageEndTokenIndex = currentTokenPointer;
    int currentTokenIndex = pageEndTokenIndex - 1;

    // Build page by adding words backward one by one until overflow
    // Use word packing to optimize line filling
    while (currentTokenIndex >= 0) {
      final prevTokenIndex = currentTokenIndex - 1;
      final prevStartOffset = prevTokenIndex >= 0
          ? tokenSpans[prevTokenIndex].start
          : 0;

      final candidateText = block.text.substring(prevStartOffset, pageEndOffset);
      final isFirstToken = prevTokenIndex < 0;
      final spacingAfter = isFirstToken ? block.spacingAfter : 0.0;
      
      // Get fragments to account for inline images
      final candidateFragments = block.sliceFragments(
        prevStartOffset,
        pageEndOffset,
        baseStyle: _baseStyle,
      );

      // Measure height with current candidate
      final currentHeight = _measureHeight(
        pageText: candidateText,
        fragments: candidateFragments,
        spacingBefore: spacingBefore,
        spacingAfter: spacingAfter,
      );
      
      // Check if it fits
      final safetyMargin = 2.0;
      if (currentHeight > effectiveMaxHeight - safetyMargin) {
        // Doesn't fit, but check if we can pack more words on existing lines
        // Try adding one more word (going further back) to see if height increases
        if (prevTokenIndex >= 0) {
          final furtherPrevTokenIndex = prevTokenIndex - 1;
          final furtherPrevStartOffset = furtherPrevTokenIndex >= 0
              ? tokenSpans[furtherPrevTokenIndex].start
              : 0;
          final extendedText = block.text.substring(furtherPrevStartOffset, pageEndOffset);
          final isExtendedFirstToken = furtherPrevTokenIndex < 0;
          final extendedSpacingAfter = isExtendedFirstToken ? block.spacingAfter : 0.0;
          final extendedFragments = block.sliceFragments(
            furtherPrevStartOffset,
            pageEndOffset,
            baseStyle: _baseStyle,
          );
          final extendedHeight = _measureHeight(
            pageText: extendedText,
            fragments: extendedFragments,
            spacingBefore: spacingBefore,
            spacingAfter: extendedSpacingAfter,
          );
          
          // If height didn't increase (within tolerance), word fits on existing line
          if ((extendedHeight - currentHeight).abs() < 0.5) {
            // Height stayed same - word fits on existing line, keep it
            currentTokenIndex = prevTokenIndex;
            continue;
          }
          
          // Height increased - check if it still fits
          if (extendedHeight <= effectiveMaxHeight - safetyMargin) {
            // New line created but still fits
            currentTokenIndex = prevTokenIndex;
            continue;
          }
        }
        // Can't fit more, stop
        break;
      }

      // It fits, continue to previous word
      currentTokenIndex = prevTokenIndex;
    }

    // Build page with the words that fit
    if (currentTokenIndex < pageEndTokenIndex - 1) {
      final pageStartOffset = currentTokenIndex >= 0
          ? tokenSpans[currentTokenIndex].start
          : 0;

      final pageText = block.text.substring(pageStartOffset, pageEndOffset);
      final tokensInPage = pageEndTokenIndex - currentTokenIndex - 1;
      final isFirstToken = currentTokenIndex < 0;
      final spacingAfter = isFirstToken ? block.spacingAfter : 0.0;

      final fragments = block.sliceFragments(
        pageStartOffset,
        pageEndOffset,
        baseStyle: _baseStyle,
      );

      final endWordPointer = globalWordIndex;
      final startWordPointer = tokensInPage > 0
          ? endWordPointer - tokensInPage + 1
          : endWordPointer;

      final page = PageContent(
        blocks: [
          TextPageBlock(
            text: pageText,
            fragments: fragments,
            textAlign: block.textAlign,
            baseStyle: _baseStyle,
            spacingBefore: spacingBefore,
            spacingAfter: spacingAfter,
            lineHeight: block.lineHeight,
          ),
        ],
        chapterIndex: block.chapterIndex,
        startWordIndex: startWordPointer,
        endWordIndex: endWordPointer,
        startCharIndex: globalCharIndex - pageText.length + 1,
        endCharIndex: globalCharIndex,
      );

      // Update state
      final nextTokenPointer = currentTokenIndex + 1;
      final nextOffset = pageStartOffset;
      final nextLineIndex = _findLineIndexForOffset(nextOffset);

      currentLineIndex = nextLineIndex;
      currentTextOffset = nextOffset;
      currentTokenPointer = nextTokenPointer;

      if (_tracingEnabled) {
        final pageHeight = _measureHeight(
          pageText: pageText,
          fragments: fragments,
          spacingBefore: spacingBefore,
          spacingAfter: spacingAfter,
        );
        _trace(
          'previous page built height=${pageHeight.toStringAsFixed(2)} '
          'tokens=$tokensInPage chars=${pageText.length} '
          'startOffset=$nextOffset',
        );
      }

      final nextCursor = nextTokenPointer <= 0
          ? null
          : TextCursorSnapshot(
              lineIndex: currentLineIndex,
              textOffset: currentTextOffset,
              tokenPointer: currentTokenPointer,
            );

      return _TextPageResult(
        page: page,
        charactersInPage: pageText.length,
        tokensInPage: tokensInPage,
        blockCompleted: nextTokenPointer <= 0,
        nextCursor: nextCursor,
      );
    }

    // Edge case: no words fit backward (shouldn't happen, but handle it)
    // If even one word doesn't fit, we still need to place it
    if (pageEndTokenIndex > 0) {
      final singleToken = tokenSpans[pageEndTokenIndex - 1];
      final pageText = block.text.substring(singleToken.start, pageEndOffset);
      final isFirstToken = pageEndTokenIndex == 1;
      final spacingAfter = isFirstToken ? block.spacingAfter : 0.0;

      final fragments = block.sliceFragments(
        singleToken.start,
        pageEndOffset,
        baseStyle: _baseStyle,
      );

      final page = PageContent(
        blocks: [
          TextPageBlock(
            text: pageText,
            fragments: fragments,
            textAlign: block.textAlign,
            baseStyle: _baseStyle,
            spacingBefore: spacingBefore,
            spacingAfter: spacingAfter,
            lineHeight: block.lineHeight,
          ),
        ],
        chapterIndex: block.chapterIndex,
        startWordIndex: globalWordIndex,
        endWordIndex: globalWordIndex,
        startCharIndex: globalCharIndex - pageText.length + 1,
        endCharIndex: globalCharIndex,
      );

      final nextTokenPointer = pageEndTokenIndex - 1;
      final nextOffset = singleToken.start;
      final nextLineIndex = _findLineIndexForOffset(nextOffset);

      currentLineIndex = nextLineIndex;
      currentTextOffset = nextOffset;
      currentTokenPointer = nextTokenPointer;

      final nextCursor = nextTokenPointer <= 0
          ? null
          : TextCursorSnapshot(
              lineIndex: currentLineIndex,
              textOffset: currentTextOffset,
              tokenPointer: currentTokenPointer,
            );

      return _TextPageResult(
        page: page,
        charactersInPage: pageText.length,
        tokensInPage: 1,
        blockCompleted: nextTokenPointer <= 0,
        nextCursor: nextCursor,
      );
    }

    return null;
  }

  double _measureHeight({
    required String pageText,
    List<InlineSpanFragment>? fragments,
    required double spacingBefore,
    required double spacingAfter,
  }) {
    if (pageText.isEmpty && (fragments == null || fragments.isEmpty)) {
      return spacingBefore + spacingAfter;
    }

    // Build span with fragments if provided (to account for inline images)
    final InlineSpan span;
    final List<PlaceholderDimensions> placeholderDimensions = [];
    
    if (fragments != null && fragments.isNotEmpty) {
      final children = <InlineSpan>[];
      for (final fragment in fragments) {
        if (fragment.type == InlineFragmentType.text) {
          children.add(TextSpan(text: fragment.text, style: fragment.style));
        } else if (fragment.type == InlineFragmentType.image && fragment.image != null) {
          final image = fragment.image!;
          final size = _resolvePlaceholderSize(image);
          placeholderDimensions.add(
            PlaceholderDimensions(
              size: size,
              alignment: image.alignment,
              baseline: image.baseline,
              baselineOffset: image.baseline == TextBaseline.alphabetic ? size.height : null,
            ),
          );
          children.add(
            WidgetSpan(
              alignment: image.alignment,
              baseline: image.baseline,
              child: SizedBox(width: size.width, height: size.height),
            ),
          );
        }
      }
      span = TextSpan(style: _baseStyle, children: children);
    } else {
      span = TextSpan(text: pageText, style: _baseStyle);
    }

    final painter = TextPainter(
      text: span,
      textAlign: block.textAlign,
      textDirection: TextDirection.ltr,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
    );
    
    if (placeholderDimensions.isNotEmpty) {
      painter.setPlaceholderDimensions(placeholderDimensions);
    }
    
    painter.layout(maxWidth: _maxWidth);
    final textHeight = painter.height;
    
    return spacingBefore + textHeight + spacingAfter;
  }

  bool _fitsWithinHeight({
    required String pageText,
    List<InlineSpanFragment>? fragments,
    required double spacingBefore,
    required double spacingAfter,
  }) {
    final totalHeight = _measureHeight(
      pageText: pageText,
      fragments: fragments,
      spacingBefore: spacingBefore,
      spacingAfter: spacingAfter,
    );

    // Safety margin for rounding errors and measurement accuracy
    // painter.height already accounts for descenders
    final safetyMargin = 2.0;
    final fits = totalHeight <= effectiveMaxHeight - safetyMargin;
    
    if (_tracingEnabled) {
      _trace(
        'fit height=${totalHeight.toStringAsFixed(2)} '
        'limit=${effectiveMaxHeight.toStringAsFixed(2)} '
        'safetyMargin=${safetyMargin.toStringAsFixed(2)} '
        'textLength=${pageText.length}',
      );
    }
    return fits;
  }

  int _findTokenIndexAfterOffset(int offset, int startIndex) {
    var index = startIndex;
    while (index < tokenSpans.length && tokenSpans[index].end <= offset) {
      index++;
    }
    return index;
  }

  int _safeBreakOffsetForTokenPointer(int tokenPointer, int fallbackStart) {
    if (tokenPointer <= 0) {
      return fallbackStart;
    }
    if (tokenPointer >= tokenSpans.length) {
      return block.text.length;
    }
    return tokenSpans[tokenPointer].start;
  }

  int _findLineIndexForOffset(int offset) {
    int low = currentLineIndex;
    int high = lines.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (offset < lineStartOffsets[mid]) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low;
  }

  _ResolvedInlineSpan _buildFullSpan(TextStyle baseStyle) {
    final fragments = block.sliceFragments(
      0,
      block.text.length,
      baseStyle: baseStyle,
    );
    final children = <InlineSpan>[];
    final placeholderDimensions = <PlaceholderDimensions>[];
    for (final fragment in fragments) {
      if (fragment.type == InlineFragmentType.text) {
        children.add(
          TextSpan(
            text: fragment.text,
            style: fragment.style,
          ),
        );
      } else if (fragment.type == InlineFragmentType.image &&
          fragment.image != null) {
        final image = fragment.image!;
        final size = _resolvePlaceholderSize(image);
        placeholderDimensions.add(
          PlaceholderDimensions(
            size: size,
            alignment: image.alignment,
            baseline: image.baseline,
            baselineOffset:
                image.baseline == TextBaseline.alphabetic ? size.height : null,
          ),
        );
        children.add(
          WidgetSpan(
            alignment: image.alignment,
            baseline: image.baseline,
            child: SizedBox(width: size.width, height: size.height),
          ),
        );
      }
    }

    return _ResolvedInlineSpan(
      span: TextSpan(style: baseStyle, children: children),
      placeholderDimensions: placeholderDimensions,
    );
  }

  Size _resolvePlaceholderSize(InlineImageContent image) {
    final fontSize = _baseStyle.fontSize ?? 16.0;
    double width = image.intrinsicWidth ?? fontSize * 2;
    double height = image.intrinsicHeight ?? fontSize * 2;
    if (width > _maxWidth) {
      final scale = _maxWidth / width;
      width = _maxWidth;
      height *= scale;
    }
    final maxHeight = _originalMaxHeight * 0.6;
    if (height > maxHeight) {
      final scale = maxHeight / height;
      height = maxHeight;
      width *= scale;
    }
    return Size(width, height);
  }
}

class _ResolvedInlineSpan {
  const _ResolvedInlineSpan({
    required this.span,
    required this.placeholderDimensions,
  });

  final InlineSpan span;
  final List<PlaceholderDimensions> placeholderDimensions;
}

class _TextPageResult {
  const _TextPageResult({
    required this.page,
    required this.charactersInPage,
    required this.tokensInPage,
    required this.blockCompleted,
    required this.nextCursor,
  });

  final PageContent page;
  final int charactersInPage;
  final int tokensInPage;
  final bool blockCompleted;
  final TextCursorSnapshot? nextCursor;
}

