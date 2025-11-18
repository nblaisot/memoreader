import 'html_blocks.dart';
import 'block_height_measurer.dart';

class Paginator {
  Paginator({
    required this.blocks,
    required this.pageHeight,
    required this.measurer,
  }) {
    _breakpoints.add(0);
  }

  final List<HtmlBlock> blocks;
  final double pageHeight;
  final BlockHeightMeasurer measurer;

  final List<int> _breakpoints = [];
  final Map<int, PageResult> _pageCache = {};

  PageResult? pageFrom(int startIndex) {
    if (startIndex >= blocks.length) return null;
    _ensureBreakpoint(startIndex);
    if (_pageCache.containsKey(startIndex)) {
      return _pageCache[startIndex];
    }

    var cursor = startIndex;
    var accumulated = 0.0;
    final pageBlocks = <HtmlBlock>[];

    while (cursor < blocks.length) {
      final block = blocks[cursor];
      final height = measurer.measure(block);
      final candidateHeight = accumulated + block.spacingBefore + height + block.spacingAfter;
      if (candidateHeight <= pageHeight || pageBlocks.isEmpty) {
        pageBlocks.add(block);
        accumulated = candidateHeight;
        cursor++;
      } else {
        break;
      }
    }

    if (pageBlocks.isEmpty) {
      return null;
    }

    final result = PageResult(
      blocks: pageBlocks,
      startBlockIndex: startIndex,
      nextBlockIndex: cursor,
    );
    _pageCache[startIndex] = result;
    if (!_breakpoints.contains(cursor)) {
      _breakpoints.add(cursor);
      _breakpoints.sort();
    }
    return result;
  }

  int? previousStart(int currentStart) {
    _ensureBreakpoint(currentStart);
    _breakpoints.sort();
    final index = _breakpoints.indexOf(currentStart);
    if (index <= 0) return null;
    return _breakpoints[index - 1];
  }

  void _ensureBreakpoint(int targetStart) {
    if (_breakpoints.contains(targetStart) || targetStart == 0) {
      return;
    }
    _breakpoints.sort();
    var anchor = 0;
    for (final bp in _breakpoints) {
      if (bp <= targetStart) {
        anchor = bp;
      }
    }

    var cursor = anchor;
    while (cursor < targetStart) {
      final page = pageFrom(cursor);
      if (page == null || page.nextBlockIndex == cursor) {
        break;
      }
      cursor = page.nextBlockIndex;
    }
    if (!_breakpoints.contains(targetStart)) {
      _breakpoints.add(targetStart);
    }
  }

  void clear() {
    _pageCache.clear();
    _breakpoints
      ..clear()
      ..add(0);
  }
}
