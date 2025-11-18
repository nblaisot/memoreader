import 'package:flutter/material.dart';

import '../../models/book.dart';
import 'block_height_measurer.dart';
import 'chapter_loader.dart';
import 'html_blocks.dart';
import 'paginator.dart';

class ReaderState extends ChangeNotifier {
  ReaderState({
    required this.book,
    required this.chapters,
    required BlockHeightMeasurer measurer,
    required this.pageHeight,
    required this.pageWidth,
    required TextStyle baseStyle,
  }) {
    _baseStyle = baseStyle;
    _measurer = measurer;
    _initPaginators();
  }

  final Book book;
  final List<ChapterData> chapters;
  late BlockHeightMeasurer _measurer;
  final double pageHeight;
  final double pageWidth;
  late TextStyle _baseStyle;

  int _chapterIndex = 0;
  int _blockIndex = 0;
  PageResult? _currentPage;
  late List<Paginator> _paginators;

  int get chapterIndex => _chapterIndex;
  PageResult? get currentPage => _currentPage;
  TextStyle get baseStyle => _baseStyle;

  void _initPaginators() {
    _paginators = chapters
        .map(
          (chapter) => Paginator(
            blocks: chapter.blocks,
            pageHeight: pageHeight,
            measurer: _measurer,
          ),
        )
        .toList();
    _currentPage = _paginators[_chapterIndex].pageFrom(_blockIndex);
  }

  Future<void> updateLayout({
    required double maxWidth,
    required double maxHeight,
    required TextStyle style,
  }) async {
    _baseStyle = style;
    for (final chapter in chapters) {
      for (final block in chapter.blocks) {
        block.measuredHeight = null;
      }
    }
    _currentPage = null;
    _blockIndex = 0;
    _chapterIndex = 0;
    _measurer = BlockHeightMeasurer(
      maxWidth: maxWidth,
      pageHeight: maxHeight,
      baseStyle: style,
      devicePixelRatio: _measurer.devicePixelRatio,
    );
    _paginators = chapters
        .map(
          (chapter) => Paginator(
            blocks: chapter.blocks,
            pageHeight: maxHeight,
            measurer: _measurer,
          ),
        )
        .toList();
    _currentPage = _paginators[_chapterIndex].pageFrom(_blockIndex);
    notifyListeners();
  }

  void goToPageStart(int blockIndex) {
    _blockIndex = blockIndex.clamp(0, chapters[_chapterIndex].blocks.length);
    _currentPage = _paginators[_chapterIndex].pageFrom(_blockIndex);
    notifyListeners();
  }

  void nextPage() {
    final paginator = _paginators[_chapterIndex];
    final page = paginator.pageFrom(_blockIndex);
    if (page == null) return;
    _blockIndex = page.nextBlockIndex;
    _currentPage = page;

    // Move to next chapter if needed
    if (_blockIndex >= chapters[_chapterIndex].blocks.length &&
        _chapterIndex < chapters.length - 1) {
      _chapterIndex++;
      _blockIndex = 0;
      _currentPage = _paginators[_chapterIndex].pageFrom(_blockIndex);
    }
    notifyListeners();
  }

  void previousPage() {
    final paginator = _paginators[_chapterIndex];
    final prevStart = paginator.previousStart(_blockIndex);
    if (prevStart != null) {
      _blockIndex = prevStart;
      _currentPage = paginator.pageFrom(_blockIndex);
      notifyListeners();
      return;
    }

    if (_chapterIndex > 0) {
      _chapterIndex--;
      final previousPaginator = _paginators[_chapterIndex];
      final start = previousPaginator.previousStart(chapters[_chapterIndex].blocks.length) ?? 0;
      _blockIndex = start;
      _currentPage = previousPaginator.pageFrom(start);
      notifyListeners();
    }
  }

  static Future<ReaderState> create({
    required Book book,
    required double pageWidth,
    required double pageHeight,
    required TextStyle baseStyle,
    required double devicePixelRatio,
  }) async {
    final loader = ChapterLoader();
    final chapters = await loader.load(book);
    final measurer = BlockHeightMeasurer(
      maxWidth: pageWidth,
      pageHeight: pageHeight,
      baseStyle: baseStyle,
      devicePixelRatio: devicePixelRatio,
    );

    return ReaderState(
      book: book,
      chapters: chapters,
      measurer: measurer,
      pageHeight: pageHeight,
      pageWidth: pageWidth,
      baseStyle: baseStyle,
    );
  }
}
