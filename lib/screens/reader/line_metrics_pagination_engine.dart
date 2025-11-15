import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
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
  })  : _bookId = bookId,
        _blocks = blocks,
        _baseTextStyle = baseTextStyle,
        _maxWidth = maxWidth,
        _originalMaxHeight = maxHeight,
        _maxHeight = maxHeight,
        _textHeightBehavior = textHeightBehavior,
        _textScaler = textScaler,
        _cacheManager = cacheManager,
        _layoutKey = _computeLayoutKey(
          baseTextStyle: baseTextStyle,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          textHeightBehavior: textHeightBehavior,
          textScaler: textScaler,
        ) {
    _textStates = List<_TextBlockState?>.filled(_blocks.length, null);
    _imageConsumed = List<bool>.filled(_blocks.length, false);
  }

  static const double _minBreakPointMargin = 24.0;
  static const double _maxBreakPointMargin = 80.0;
  static const double _minPageBottomMargin = 48.0;
  static const double _maxBottomMarginFraction = 0.18;

  final String _bookId;
  final List<DocumentBlock> _blocks;
  final TextStyle _baseTextStyle;
  final double _maxWidth;
  final double _originalMaxHeight;
  final double _maxHeight;
  final TextHeightBehavior _textHeightBehavior;
  final TextScaler _textScaler;
  final PaginationCacheManager? _cacheManager;
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
  }) {
    final buffer = StringBuffer()
      ..write('v2|')
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
      ..write(textScaler.hashCode);
    return base64UrlEncode(buffer.toString().codeUnits);
  }

  void _restoreFromCache(PaginationCacheEntry cache) {
    for (final cachedPage in cache.pages) {
      final pageBlocks = <PageBlock>[];
      for (final blockData in cachedPage.blocks) {
        if (blockData.type == 'text') {
          final color = blockData.color != null
              ? Color(blockData.color!)
              : _baseTextStyle.color;
          final fontWeight = blockData.fontWeight != null
              ? FontWeight.values[blockData.fontWeight!.clamp(0, FontWeight.values.length - 1)]
              : _baseTextStyle.fontWeight ?? FontWeight.normal;
          final fontStyle = blockData.fontStyle == 'italic'
              ? FontStyle.italic
              : FontStyle.normal;
          final textStyle = _baseTextStyle.copyWith(
            fontSize: blockData.fontSize ?? _baseTextStyle.fontSize,
            height: blockData.height ?? _baseTextStyle.height,
            color: color,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            fontFamily: blockData.fontFamily ?? _baseTextStyle.fontFamily,
          );
          pageBlocks.add(TextPageBlock(
            text: blockData.text ?? '',
            style: textStyle,
            textAlign: TextAlign.values[blockData.textAlign?.clamp(0, TextAlign.values.length - 1) ?? TextAlign.left.index],
            spacingBefore: blockData.spacingBefore,
            spacingAfter: blockData.spacingAfter,
          ));
        } else {
          pageBlocks.add(ImagePageBlock(
            bytes: Uint8List.fromList(blockData.imageBytes ?? <int>[]),
            height: blockData.imageHeight ?? _maxHeight,
            spacingBefore: blockData.spacingBefore,
            spacingAfter: blockData.spacingAfter,
          ));
        }
      }
      _pages.add(PageContent(
        blocks: pageBlocks,
        chapterIndex: cachedPage.chapterIndex,
        startWordIndex: cachedPage.startWordIndex,
        endWordIndex: cachedPage.endWordIndex,
        startCharIndex: cachedPage.startCharIndex,
        endCharIndex: cachedPage.endCharIndex,
      ));
    }

    _totalCharacters = cache.totalCharacters;
    _isComplete = cache.isComplete;
    if (_isComplete) {
      _finalPageCount = _pages.length;
    }
    _cursor = cache.cursor;

    if (_cursor != null) {
      for (int i = 0; i < _cursor!.blockIndex && i < _blocks.length; i++) {
        if (_blocks[i] is TextDocumentBlock) {
          final state = _obtainTextState(i);
          state.markComplete();
        } else if (_blocks[i] is ImageDocumentBlock) {
          _imageConsumed[i] = true;
        }
      }

      final int blockIndex = _cursor!.blockIndex;
      if (blockIndex < _blocks.length &&
          _blocks[blockIndex] is TextDocumentBlock &&
          _cursor!.textState != null) {
        final state = _obtainTextState(blockIndex);
        state.applyCursor(_cursor!.textState!);
      }
    }
  }

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
    _ongoingSave = _cacheManager!
        .save(_bookId, _layoutKey, entry)
        .catchError((_) => null);
    await _ongoingSave;
  }

  CachedPageData _toCachedPage(PageContent page) {
    final blocks = <CachedPageBlockData>[];
    for (final block in page.blocks) {
      if (block is TextPageBlock) {
        final style = block.style;
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
    if (_cursor == null) {
      _cursor = PaginationCursorSnapshot(
        blockIndex: 0,
        globalCharIndex: 0,
        globalWordIndex: 0,
        textState: const TextCursorSnapshot(
          lineIndex: 0,
          textOffset: 0,
          tokenPointer: 0,
        ),
      );
    }

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
    final target = lineHeight * 0.75;
    return target.clamp(_minBreakPointMargin, _maxBreakPointMargin);
  }

  double _computePageBottomMargin(double lineHeight, double spacingAfter) {
    final dynamicMargin = lineHeight + spacingAfter;
    final upperBound = _originalMaxHeight * _maxBottomMarginFraction;
    final effectiveUpperBound = math.max(_minPageBottomMargin, upperBound);
    return dynamicMargin.clamp(_minPageBottomMargin, effectiveUpperBound);
  }

  PageContent? _createImagePage(
    ImageDocumentBlock block,
    int startCharIndex,
    int startWordIndex,
    bool isFirstBlock,
  ) {
    final spacingBefore = isFirstBlock ? 0.0 : block.spacingBefore;
    final spacingAfter = block.spacingAfter;

    final intrinsicWidth = block.intrinsicWidth ?? _maxWidth;
    final intrinsicHeight = block.intrinsicHeight ?? (_maxWidth * 0.6);

    double fittedHeight = intrinsicHeight;
    if (intrinsicWidth > 0 && intrinsicHeight > 0) {
      final scale = _maxWidth / intrinsicWidth;
      fittedHeight = intrinsicHeight * scale;
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
  })  : _maxWidth = maxWidth,
        _maxHeight = maxHeight,
        _originalMaxHeight = originalMaxHeight,
        _textHeightBehavior = textHeightBehavior,
        _textScaler = textScaler,
        _computeBreakPointMargin = computeBreakPointMargin,
        _computePageBottomMargin = computePageBottomMargin {
    textStyle = baseTextStyle.copyWith(
      fontSize: (baseTextStyle.fontSize ?? 16) * block.fontScale,
      fontWeight: block.fontWeight,
      fontStyle: block.fontStyle,
    );

    textPainter = TextPainter(
      text: TextSpan(text: block.text, style: textStyle),
      textAlign: block.textAlign,
      textDirection: TextDirection.ltr,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
    );
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
    effectiveMaxHeight = _originalMaxHeight - pageBottomMargin;
  }

  final TextDocumentBlock block;
  late final TextStyle textStyle;
  late final TextPainter textPainter;
  late final List<LineMetrics> lines;
  late final List<int> lineStartOffsets;
  late final List<TokenSpan> tokenSpans;
  final double _maxWidth;
  final double _maxHeight;
  final double _originalMaxHeight;
  final TextHeightBehavior _textHeightBehavior;
  final TextScaler _textScaler;
  final double Function(double lineHeight) _computeBreakPointMargin;
  final double Function(double lineHeight, double spacingAfter)
      _computePageBottomMargin;

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

    final spacingBefore = currentTextOffset == 0
        ? (isFirstBlock ? 0.0 : block.spacingBefore)
        : 0.0;

    double currentPageHeight = spacingBefore;
    int pageStartTextIndex = currentTextOffset;
    int pageStartTokenIndex = currentTokenPointer;

    for (int lineIndex = currentLineIndex;
        lineIndex < lines.length;
        lineIndex++) {
      final line = lines[lineIndex];
      final lineHeight = line.height;
      final lineStartOffset = lineStartOffsets[lineIndex];
      final breakPointMargin = _computeBreakPointMargin(lineHeight);
      final left = line.left;
      final top = line.baseline - line.ascent;

      final isLastLine = lineIndex == lines.length - 1;
      final effectiveSpacingAfter = isLastLine ? block.spacingAfter : 0.0;
      final totalHeightWithLine =
          currentPageHeight + lineHeight + effectiveSpacingAfter;

      if (totalHeightWithLine > effectiveMaxHeight &&
          pageStartTextIndex < lineStartOffset) {
        final breakPointTop = (top - breakPointMargin).clamp(0.0, double.infinity);
        final breakPointOffset = textPainter
            .getPositionForOffset(Offset(left, breakPointTop))
            .offset;

        final targetBreakOffset = breakPointOffset > pageStartTextIndex
            ? breakPointOffset
            : lineStartOffset;

        int pageEndTokenPointerExclusive =
            _findTokenIndexAfterOffset(targetBreakOffset, pageStartTokenIndex);
        int safeBreakOffset = _safeBreakOffsetForTokenPointer(
          pageEndTokenPointerExclusive,
          pageStartTextIndex,
        );

        if (safeBreakOffset <= pageStartTextIndex &&
            lineStartOffset > pageStartTextIndex) {
          pageEndTokenPointerExclusive = _findTokenIndexAfterOffset(
            lineStartOffset,
            pageStartTokenIndex,
          );
          safeBreakOffset = _safeBreakOffsetForTokenPointer(
            pageEndTokenPointerExclusive,
            pageStartTextIndex,
          );
        }

        if (safeBreakOffset <= pageStartTextIndex &&
            pageStartTokenIndex < tokenSpans.length) {
          final forcedPointer = pageStartTokenIndex + 1;
          pageEndTokenPointerExclusive = forcedPointer < tokenSpans.length
              ? forcedPointer
              : tokenSpans.length;
          if (pageEndTokenPointerExclusive > 0) {
            safeBreakOffset =
                tokenSpans[pageEndTokenPointerExclusive - 1].end;
          } else {
            safeBreakOffset = block.text.length;
          }
        }

        if (safeBreakOffset > pageStartTextIndex) {
          final fitResult = _shrinkToFit(
            startOffset: pageStartTextIndex,
            endOffset: safeBreakOffset,
            startTokenPointer: pageStartTokenIndex,
            endTokenPointerExclusive: pageEndTokenPointerExclusive,
            spacingBefore: spacingBefore,
            spacingAfter: 0.0,
          );

          if (fitResult != null && fitResult.text.isNotEmpty) {
            final tokensInPage =
                fitResult.endTokenPointerExclusive - pageStartTokenIndex;
            final startWordPointer = globalWordIndex;
            final endWordPointer = tokensInPage > 0
                ? startWordPointer + tokensInPage - 1
                : startWordPointer - 1;

            final page = PageContent(
              blocks: [
                TextPageBlock(
                  text: fitResult.text,
                  style: textStyle,
                  textAlign: block.textAlign,
                  spacingBefore: spacingBefore,
                  spacingAfter: 0.0,
                ),
              ],
              chapterIndex: block.chapterIndex,
              startWordIndex: startWordPointer,
              endWordIndex: endWordPointer,
              startCharIndex: globalCharIndex,
              endCharIndex: globalCharIndex + fitResult.text.length - 1,
            );

            final nextOffset = fitResult.endOffset;
            final nextTokenPointer = fitResult.endTokenPointerExclusive;
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
              charactersInPage: fitResult.text.length,
              tokensInPage: tokensInPage,
              blockCompleted: blockCompleted,
              nextCursor: nextCursor,
            );
          }
        }
      }

      currentPageHeight += lineHeight;

      if (isLastLine) {
        final fitResult = _shrinkToFit(
          startOffset: pageStartTextIndex,
          endOffset: block.text.length,
          startTokenPointer: pageStartTokenIndex,
          endTokenPointerExclusive: tokenSpans.length,
          spacingBefore: spacingBefore,
          spacingAfter: block.spacingAfter,
        );

        if (fitResult != null && fitResult.text.isNotEmpty) {
          final tokensInPage =
              fitResult.endTokenPointerExclusive - pageStartTokenIndex;
          final startWordPointer = globalWordIndex;
          final endWordPointer = tokensInPage > 0
              ? startWordPointer + tokensInPage - 1
              : startWordPointer - 1;

          final page = PageContent(
            blocks: [
              TextPageBlock(
                text: fitResult.text,
                style: textStyle,
                textAlign: block.textAlign,
                spacingBefore: spacingBefore,
                spacingAfter: block.spacingAfter,
              ),
            ],
            chapterIndex: block.chapterIndex,
            startWordIndex: startWordPointer,
            endWordIndex: endWordPointer,
            startCharIndex: globalCharIndex,
            endCharIndex: globalCharIndex + fitResult.text.length - 1,
          );

          markComplete();

          return _TextPageResult(
            page: page,
            charactersInPage: fitResult.text.length,
            tokensInPage: tokensInPage,
            blockCompleted: true,
            nextCursor: null,
          );
        }
      }
    }

    markComplete();
    return null;
  }

  _FitResult? _shrinkToFit({
    required int startOffset,
    required int endOffset,
    required int startTokenPointer,
    required int endTokenPointerExclusive,
    required double spacingBefore,
    required double spacingAfter,
  }) {
    int currentEndOffset = endOffset;
    int currentEndTokenPointerExclusive = endTokenPointerExclusive;

    while (currentEndOffset > startOffset) {
      final pageText = block.text.substring(startOffset, currentEndOffset);
      if (_fitsWithinHeight(
        pageText: pageText,
        spacingBefore: spacingBefore,
        spacingAfter: spacingAfter,
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
  }) {
    if (pageText.isEmpty) {
      return true;
    }

    final painter = TextPainter(
      text: TextSpan(text: pageText, style: textStyle),
      textAlign: block.textAlign,
      textDirection: TextDirection.ltr,
      textHeightBehavior: _textHeightBehavior,
      textScaler: _textScaler,
    );
    painter.layout(maxWidth: _maxWidth);

    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) {
      return true;
    }

    double totalHeight = spacingBefore;
    for (final line in metrics) {
      totalHeight += line.height;
    }
    totalHeight += spacingAfter;

    final roundedHeight = totalHeight.ceilToDouble();
    return roundedHeight <= effectiveMaxHeight;
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
