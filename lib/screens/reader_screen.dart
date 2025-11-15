import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:epubx/epubx.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:image/image.dart' as img show decodeImage;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import '../services/enhanced_summary_service.dart';
import '../services/summary_config_service.dart';
import '../services/settings_service.dart';
import '../utils/html_text_extractor.dart';
import 'reader/document_model.dart';
import 'reader/line_metrics_pagination_engine.dart';
import 'reader/pagination_cache.dart';
import 'reader/tap_zones.dart';
import 'settings_screen.dart';
import 'summary_screen.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book});

  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  static const double _defaultHorizontalPadding = 30.0; // Default horizontal padding
  static const double _defaultVerticalPadding = 50.0; // Default vertical padding
  static const double _paragraphSpacing = 18.0;
  static const double _headingSpacing = 28.0;

  final BookService _bookService = BookService();
  final SettingsService _settingsService = SettingsService();
  final PaginationCacheManager _paginationCacheManager =
      const PaginationCacheManager();
  EnhancedSummaryService? _summaryService;
  final PageController _pageController = PageController(initialPage: 1);
  
  double _horizontalPadding = _defaultHorizontalPadding; // Will be loaded from settings
  double _verticalPadding = _defaultVerticalPadding; // Will be loaded from settings

  Size? _lastActualSize;

  EpubBook? _epubBook;
  List<DocumentBlock> _docBlocks = [];
  List<_ChapterEntry> _chapterEntries = [];

  LineMetricsPaginationEngine? _engine;
  
  int _currentPageIndex = 0;
  int _totalPages = 0;
  double _progress = 0;

  bool _isLoading = true;
  String? _errorMessage;

  bool _showProgressBar = false;
  double _fontSize = 18.0;

  ReadingProgress? _savedProgress;
  Timer? _progressDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSummaryService();
    _loadVerticalPadding();
    _loadBook();
  }

  Future<void> _loadVerticalPadding() async {
    final horizontal = await _settingsService.getHorizontalPadding();
    final vertical = await _settingsService.getVerticalPadding();
    if (mounted) {
      setState(() {
        _horizontalPadding = horizontal;
        _verticalPadding = vertical;
      });
    }
  }

  Future<void> _initializeSummaryService() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configService = SummaryConfigService(prefs);
      final baseService = await configService.getSummaryService();
      if (baseService != null) {
        setState(() {
          _summaryService = EnhancedSummaryService(baseService, prefs);
        });
      }
    } catch (e) {
      debugPrint('Failed to initialize summary service: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _engine?.removeListener(_handleEngineUpdate);
    _pageController.dispose();
    _progressDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!_isLoading && mounted) {
      _scheduleRepagination(retainCurrentPage: true);
    }
  }

  Future<void> _loadBook() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final epub = await _bookService.loadEpubBook(widget.book.filePath);
      final progress = await _bookService.getReadingProgress(widget.book.id);
      final extraction = await _extractDocument(epub);

      setState(() {
        _epubBook = epub;
        _docBlocks = extraction.blocks;
        _chapterEntries = extraction.chapters;
        _savedProgress = progress;
        _isLoading = false;
      });

      final initialCharIndex =
          progress?.currentCharacterIndex ?? progress?.currentWordIndex ?? 0;
      _scheduleRepagination(initialCharIndex: initialCharIndex);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _scheduleRepagination({int? initialCharIndex, bool retainCurrentPage = false, Size? actualSize}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _docBlocks.isEmpty) return;
      int targetCharIndex;
      if (retainCurrentPage) {
        // Get current page's start char index
        final currentPage = _engine?.getPage(_currentPageIndex);
        targetCharIndex = currentPage?.startCharIndex ?? 0;
      } else if (initialCharIndex != null) {
        targetCharIndex = initialCharIndex;
      } else {
        targetCharIndex =
            _savedProgress?.currentCharacterIndex ?? _savedProgress?.currentWordIndex ?? 0;
      }
      unawaited(_rebuildPagination(targetCharIndex, actualSize: actualSize));
    });
  }

  Future<void> _rebuildPagination(int startCharIndex, {Size? actualSize}) async {
    if (!mounted || _docBlocks.isEmpty) return;

    Size? sizeForMetrics = actualSize ?? _lastActualSize;
    sizeForMetrics ??= MediaQuery.of(context).size;
    final baseMetrics = _computePageMetrics(context, sizeForMetrics);
    final metrics = _adjustForUserPadding(baseMetrics);

    final previousEngine = _engine;
    previousEngine?.removeListener(_handleEngineUpdate);

    final engine = await LineMetricsPaginationEngine.create(
      bookId: widget.book.id,
      blocks: _docBlocks,
      baseTextStyle: metrics.baseTextStyle,
      maxWidth: metrics.maxWidth,
      maxHeight: metrics.maxHeight,
      textHeightBehavior: metrics.textHeightBehavior,
      textScaler: metrics.textScaler,
      cacheManager: _paginationCacheManager,
    );

    final targetPageIndex =
        await engine.ensurePageForCharacter(startCharIndex, windowRadius: 1);
    engine.addListener(_handleEngineUpdate);
    unawaited(engine.ensureWindow(targetPageIndex, radius: 1));
    unawaited(engine.startBackgroundPagination());

    setState(() {
      _engine = engine;
      _totalPages = engine.estimatedTotalPages;
      _currentPageIndex = targetPageIndex;
      _progress = _totalPages > 0 ? (_currentPageIndex + 1) / _totalPages : 0;
      _showProgressBar = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(1);
      }
    });

    _scheduleProgressSave();
  }


  _PageMetrics _computePageMetrics(BuildContext context, Size? actualSize) {
    final mediaQuery = MediaQuery.of(context);
    // Use actualSize if provided (from LayoutBuilder), otherwise fall back to MediaQuery
    final size = actualSize ?? mediaQuery.size;
    // Use full screen width minus only system padding and margins
    final systemHorizontalPadding =
        mediaQuery.padding.left + mediaQuery.padding.right;
    // Calculate available height: screen height minus only system padding
    final systemVerticalPadding =
        mediaQuery.padding.top + mediaQuery.padding.bottom;
    final maxWidth = math.max(120.0, size.width - systemHorizontalPadding);
    final maxHeight = math.max(160.0, size.height - systemVerticalPadding);

    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.onSurface;
    // Use maybeOf to avoid error if DefaultTextHeightBehavior is not in widget tree
    // Provide default TextHeightBehavior if none is found
    final textHeightBehavior = DefaultTextHeightBehavior.maybeOf(context) ??
        const TextHeightBehavior();
    final baseStyle = theme.textTheme.bodyMedium?.copyWith(
          fontSize: _fontSize,
          height: 1.6,
          color: baseColor,
        ) ??
        TextStyle(
          fontSize: _fontSize,
          height: 1.6,
          color: baseColor,
        );

    return _PageMetrics(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      baseTextStyle: baseStyle,
      textHeightBehavior: textHeightBehavior,
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

_PageMetrics _adjustForUserPadding(_PageMetrics metrics) {
    final adjustedWidth =
        math.max(120.0, metrics.maxWidth - _horizontalPadding * 2);
    final adjustedHeight =
        math.max(160.0, metrics.maxHeight - _verticalPadding * 2);
    return _PageMetrics(
      maxWidth: adjustedWidth,
      maxHeight: adjustedHeight,
      baseTextStyle: metrics.baseTextStyle,
      textHeightBehavior: metrics.textHeightBehavior,
      textScaler: metrics.textScaler,
    );
  }

  void _scheduleProgressSave() {
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _engine == null) return;
      final page = _engine!.getPage(_currentPageIndex);
      if (page == null) return;
      _saveProgress(page);
    });
  }

  void _handleTapDown(TapDownDetails details) {
    final size = MediaQuery.of(context).size;
    final action = determineTapAction(details.globalPosition, size);

    switch (action) {
      case ReaderTapAction.showMenu:
        _openReadingMenu();
        break;
      case ReaderTapAction.showProgress:
        setState(() {
          _showProgressBar = !_showProgressBar;
        });
        break;
      case ReaderTapAction.nextPage:
        () async {
          if (_engine == null) return;
          if (!_engine!.hasNextPage(_currentPageIndex)) return;
          await _engine!.ensureWindow(_currentPageIndex + 1, radius: 1);
          if (!mounted) return;
          setState(() {
            _currentPageIndex++;
            _progress = _totalPages > 0
                ? (_currentPageIndex + 1) / _totalPages
                : _progress;
            _showProgressBar = false;
          });
          unawaited(_engine!.ensureWindow(_currentPageIndex, radius: 1));
          unawaited(_engine!.startBackgroundPagination());
          _scheduleProgressSave();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_pageController.hasClients) {
              _pageController.jumpToPage(1);
            }
          });
        }();
        break;
      case ReaderTapAction.previousPage:
        if (_currentPageIndex > 0) {
          setState(() {
            _currentPageIndex--;
            _progress = _totalPages > 0
                ? (_currentPageIndex + 1) / _totalPages
                : _progress;
            _showProgressBar = false;
          });
          unawaited(_engine?.ensureWindow(_currentPageIndex, radius: 1));
          _scheduleProgressSave();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_pageController.hasClients) {
              _pageController.jumpToPage(1);
            }
          });
        }
        break;
      case ReaderTapAction.dismissOverlays:
        if (_showProgressBar) {
          setState(() {
            _showProgressBar = false;
          });
        }
        break;
    }
  }

  Future<void> _saveProgress(PageContent page) async {
    try {
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentChapterIndex: page.chapterIndex,
        currentPageInChapter: null,
        currentWordIndex: page.startWordIndex,
        currentCharacterIndex: page.startCharIndex,
        progress: _progress,
        lastRead: DateTime.now(),
      );
      await _bookService.saveReadingProgress(progress);
    } catch (_) {
      // Saving progress is best-effort; ignore failures.
    }
  }

  void _changeFontSize(double value) {
    setState(() {
      _fontSize = value;
    });
    _scheduleRepagination(retainCurrentPage: true);
  }

  void _handlePageChanged(int pageIndex) {
    if (pageIndex == 1) return;

    if (pageIndex == 2 && _engine?.hasNextPage(_currentPageIndex) == true) {
      setState(() {
        _currentPageIndex++;
        _progress = _totalPages > 0 ? (_currentPageIndex + 1) / _totalPages : 0;
        _showProgressBar = false;
      });
      unawaited(_engine?.ensureWindow(_currentPageIndex, radius: 1));
      unawaited(_engine?.startBackgroundPagination());
      _scheduleProgressSave();
    } else if (pageIndex == 0 && _currentPageIndex > 0) {
      // Previous page
      setState(() {
        _currentPageIndex--;
        _progress = _totalPages > 0 ? (_currentPageIndex + 1) / _totalPages : 0;
        _showProgressBar = false;
      });
      unawaited(_engine?.ensureWindow(_currentPageIndex, radius: 1));
      _scheduleProgressSave();
    }

    // Reset controller to keep current page in the middle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use LayoutBuilder to get actual widget size, especially important for foldable devices
        final actualSize = Size(constraints.maxWidth, constraints.maxHeight);
        _lastActualSize = actualSize;
        final baseMetrics = _computePageMetrics(context, actualSize);
        final metrics = _adjustForUserPadding(baseMetrics);
        
        // Trigger repagination if size changed significantly
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _docBlocks.isEmpty) return;
          // Only repaginate if size changed significantly (more than 10 pixels difference)
          final currentMetrics = metrics;
          if (_engine == null ||
              !_engine!.matches(
                blocks: _docBlocks,
                baseStyle: currentMetrics.baseTextStyle,
                maxWidth: currentMetrics.maxWidth,
                maxHeight: currentMetrics.maxHeight,
                textHeightBehavior: currentMetrics.textHeightBehavior,
                textScaler: currentMetrics.textScaler,
              )) {
            _scheduleRepagination(retainCurrentPage: true, actualSize: actualSize);
          }
        });

        return _buildReaderContent(context, actualSize, metrics);
      },
    );
  }

  Widget _buildReaderContent(BuildContext context, Size actualSize, _PageMetrics metrics) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
                const SizedBox(height: 16),
                Text(_errorMessage!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: _loadBook, child: const Text('Réessayer')),
              ],
            ),
          ),
        ),
      );
    }

    // Build three pages: previous, current, and next
    final previousPage = _engine?.getPage(_currentPageIndex - 1);
    final currentPage = _engine?.getPage(_currentPageIndex);
    final nextPage = _engine?.getPage(_currentPageIndex + 1);

    final pages = <Widget>[
      _buildPageContent(previousPage, metrics),
      _buildPageContent(currentPage, metrics),
      _buildPageContent(nextPage, metrics),
    ];

    return Scaffold(
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: pages.length,
            onPageChanged: _handlePageChanged,
            itemBuilder: (context, index) => pages[index],
          ),
          // GestureDetector that covers the entire screen to catch taps
          // Use onTapDown for immediate response (not onTapUp which waits for tap completion)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (details) {
                final size = MediaQuery.of(context).size;
                final action = determineTapAction(details.globalPosition, size);
                
                switch (action) {
                  case ReaderTapAction.showMenu:
                    _openReadingMenu();
                    break;
                  case ReaderTapAction.showProgress:
                    setState(() {
                      _showProgressBar = !_showProgressBar;
                    });
                    break;
                  case ReaderTapAction.nextPage:
                    () async {
                      if (_engine == null) return;
                      if (!_engine!.hasNextPage(_currentPageIndex)) return;
                      await _engine!.ensureWindow(_currentPageIndex + 1, radius: 1);
                      if (!mounted) return;
                      setState(() {
                        _currentPageIndex++;
                        _progress = _totalPages > 0
                            ? (_currentPageIndex + 1) / _totalPages
                            : _progress;
                        _showProgressBar = false;
                      });
                      unawaited(
                          _engine!.ensureWindow(_currentPageIndex, radius: 1));
                      unawaited(_engine!.startBackgroundPagination());
                      _scheduleProgressSave();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_pageController.hasClients) {
                          _pageController.jumpToPage(1);
                        }
                      });
                    }();
                    break;
                  case ReaderTapAction.previousPage:
                    if (_currentPageIndex > 0) {
                      setState(() {
                        _currentPageIndex--;
                        _progress = _totalPages > 0 ? (_currentPageIndex + 1) / _totalPages : 0;
                        _showProgressBar = false;
                      });
                      _scheduleProgressSave();
                      unawaited(
                          _engine?.ensureWindow(_currentPageIndex, radius: 1));
                      // Reset PageView to middle page after state update
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_pageController.hasClients) {
                          _pageController.jumpToPage(1);
                        }
                      });
                    }
                    break;
                  case ReaderTapAction.dismissOverlays:
                    if (_showProgressBar) {
                      setState(() {
                        _showProgressBar = false;
                      });
                    }
                    break;
                }
              },
              child: Container(color: Colors.transparent),
            ),
          ),
          if (_showProgressBar)
            Positioned(
              bottom: 24,
              left: 24,
              right: 24,
              child: _buildProgressIndicator(theme),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator(ThemeData theme) {
    final displayProgress = (_progress * 100).clamp(0, 100).toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.92),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12)],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _currentChapterTitle ?? widget.book.title,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: theme.colorScheme.surfaceVariant,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text('$displayProgress %'),
        ],
      ),
    );
  }

  String? get _currentChapterTitle {
    if (_engine == null) return null;
    final page = _engine!.getPage(_currentPageIndex);
    final chapterIndex = page?.chapterIndex;
    if (chapterIndex == null) return null;
    if (chapterIndex < 0 || chapterIndex >= _chapterEntries.length) return null;
    return _chapterEntries[chapterIndex].title;
  }

  Widget _buildPageContent(PageContent? page, _PageMetrics metrics) {
    if (page == null) {
      // Return empty container during loading instead of showing message
      return Container();
    }

    // Center the page content with proper constraints
    return SizedBox.expand(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _horizontalPadding,
          vertical: _verticalPadding,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: _PageContentView(
            content: page,
            maxWidth: metrics.maxWidth,
            maxHeight: metrics.maxHeight,
            textHeightBehavior: metrics.textHeightBehavior,
            textScaler: metrics.textScaler,
          ),
        ),
      ),
    );
  }

  void _openReadingMenu() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Options de lecture',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    const SizedBox(height: 20),
                    // Font size slider
                    Text('Taille du texte : ${_fontSize.toStringAsFixed(0)} pt'),
                    Slider(
                      min: 14,
                      max: 30,
                      divisions: 16,
                      value: _fontSize,
                      label: '${_fontSize.toStringAsFixed(0)} pt',
                      onChanged: (value) {
                        setState(() => _fontSize = value);
                        _changeFontSize(value);
                      },
                    ),
                    const SizedBox(height: 20),
                    // Navigation to chapter
                    if (_chapterEntries.isNotEmpty)
                      ListTile(
                        leading: const Icon(Icons.list),
                        title: const Text('Aller au chapitre'),
                        onTap: () {
                          Navigator.pop(context);
                          _showChapterSelector();
                        },
                      ),
                    // Summaries
                    ListTile(
                      leading: const Icon(Icons.summarize),
                      title: const Text('Résumés'),
                      onTap: () {
                        Navigator.pop(context);
                        _openSummaries();
                      },
                    ),
                    // Back to library
                    ListTile(
                      leading: const Icon(Icons.arrow_back),
                      title: const Text('Retour à la librairie'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.pop(context);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showChapterSelector() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Sélectionner un chapitre',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _chapterEntries.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapterEntries[index];
                    return ListTile(
                      title: Text(chapter.title),
                      onTap: () {
                        Navigator.pop(context);
                        _goToChapter(chapter.index);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _goToChapter(int chapterIndex) {
    if (_engine == null) return;

    // Find the first page of this chapter
    final pageIndex = _engine!.findPageForChapter(chapterIndex);
    if (pageIndex == null) return;

    // Get that page and navigate to it
    final page = _engine!.getPage(pageIndex);
    if (page != null) {
      _scheduleRepagination(initialCharIndex: page.startCharIndex);
    }
  }

  void _handleEngineUpdate() {
    if (!mounted || _engine == null) return;
    final estimated = _engine!.estimatedTotalPages;
    setState(() {
      _totalPages = estimated;
      _progress = estimated > 0 ? (_currentPageIndex + 1) / estimated : 0;
    });
  }

  void _openSummaries() async {
    if (_engine == null) return;
    final currentPage = _engine!.getPage(_currentPageIndex);
    if (currentPage == null) return;
    
    if (_summaryService == null) {
      // Show dialog to configure API key
      if (!mounted) return;
      final shouldGoToSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Configuration requise'),
          content: const Text(
            'Pour accéder aux résumés, vous devez configurer une clé API dans les paramètres.\n\n'
            'Souhaitez-vous aller aux paramètres maintenant ?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Paramètres'),
            ),
          ],
        ),
      );
      
      if (shouldGoToSettings == true && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const SettingsScreen(),
          ),
        );
        // Reinitialize summary service in case user configured API key
        await _initializeSummaryService();
        // Reload vertical padding in case user changed it
        await _loadVerticalPadding();
        // Repaginate with new padding
        if (mounted) {
          _scheduleRepagination(retainCurrentPage: true);
        }
      }
      return;
    }
    
    final progress = ReadingProgress(
      bookId: widget.book.id,
      currentWordIndex: currentPage.startWordIndex,
      currentCharacterIndex: currentPage.startCharIndex,
      currentChapterIndex: currentPage.chapterIndex,
      currentPageInChapter: null,
      lastRead: DateTime.now(),
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SummaryScreen(
          book: widget.book,
          progress: progress,
          enhancedSummaryService: _summaryService!,
        ),
      ),
    );
  }

  Future<_DocumentExtractionResult> _extractDocument(EpubBook epub) async {
    final blocks = <DocumentBlock>[];
    final chapters = <_ChapterEntry>[];
    final images = epub.Content?.Images;

    final epubChapters = epub.Chapters ?? const <EpubChapter>[];
    for (var i = 0; i < epubChapters.length; i++) {
      final chapter = epubChapters[i];
      final title = chapter.Title?.trim().isNotEmpty == true
          ? chapter.Title!.trim()
          : 'Chapitre ${i + 1}';
      final html = chapter.HtmlContent ?? '';
      if (html.isEmpty) {
        continue;
      }
      final result = _buildBlocksFromHtml(
        html,
        chapterIndex: i,
        images: images,
      );
      if (result.isNotEmpty) {
        chapters.add(_ChapterEntry(index: i, title: title));
        blocks.addAll(result);
      }
    }

    if (blocks.isEmpty) {
      blocks.add(
        TextDocumentBlock(
          chapterIndex: 0,
          spacingBefore: 0,
          spacingAfter: _paragraphSpacing,
          text: 'Aucun contenu lisible dans ce livre.',
          fontScale: 1.0,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.italic,
          textAlign: TextAlign.center,
        ),
      );
      chapters.add(_ChapterEntry(index: 0, title: widget.book.title));
    }

    return _DocumentExtractionResult(blocks: blocks, chapters: chapters);
  }

  List<DocumentBlock> _buildBlocksFromHtml(
    String html, {
    required int chapterIndex,
    Map<String, EpubByteContentFile>? images,
  }) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) {
      return const [];
    }

    final blocks = <DocumentBlock>[];
    bool isFirstBlock = true;

    void addTextBlock({
      required String text,
      double fontScale = 1.0,
      FontWeight fontWeight = FontWeight.normal,
      FontStyle fontStyle = FontStyle.normal,
      TextAlign textAlign = TextAlign.left,
      double spacingBefore = _paragraphSpacing / 2,
      double spacingAfter = _paragraphSpacing,
    }) {
      final normalized = normalizeWhitespace(text);
      if (normalized.isEmpty) return;
      blocks.add(
        TextDocumentBlock(
          chapterIndex: chapterIndex,
          spacingBefore: isFirstBlock ? 0 : spacingBefore,
          spacingAfter: spacingAfter,
          text: normalized,
          fontScale: fontScale,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          textAlign: textAlign,
        ),
      );
      isFirstBlock = false;
    }

    void addImageBlock(String? src) {
      if (src == null) return;
      final bytes = _resolveImageBytes(src, images);
      if (bytes == null) return;
      double? width;
      double? height;
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          width = decoded.width.toDouble();
          height = decoded.height.toDouble();
        }
      } catch (_) {
        width = null;
        height = null;
      }
      blocks.add(
        ImageDocumentBlock(
          chapterIndex: chapterIndex,
          spacingBefore: isFirstBlock ? 0 : _paragraphSpacing,
          spacingAfter: _paragraphSpacing,
          bytes: bytes,
          intrinsicWidth: width,
          intrinsicHeight: height,
        ),
      );
      isFirstBlock = false;
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
            final scale = (2.2 - level * 0.2).clamp(1.2, 1.6);
            addTextBlock(
              text: node.text,
              fontScale: scale,
              fontWeight: FontWeight.w700,
              textAlign: TextAlign.center,
              spacingBefore: _headingSpacing,
              spacingAfter: _paragraphSpacing,
            );
            return;
          case 'p':
          case 'div':
          case 'section':
          case 'article':
          case 'blockquote':
            addTextBlock(text: node.text);
            for (final child in node.nodes) {
              walk(child);
            }
            return;
          case 'ul':
          case 'ol':
            final ordered = name == 'ol';
            int counter = 1;
            for (final child in node.children.where((n) => n.localName == 'li')) {
              final text = normalizeWhitespace(child.text);
              if (text.isEmpty) continue;
              final bullet = ordered ? '$counter. ' : '• ';
              addTextBlock(
                text: '$bullet$text',
                spacingBefore: _paragraphSpacing / 2,
                spacingAfter: _paragraphSpacing / 2,
              );
              counter++;
            }
            return;
          case 'img':
            addImageBlock(node.attributes['src']);
            return;
          case 'br':
            addTextBlock(text: '');
            return;
          default:
            for (final child in node.nodes) {
              walk(child);
            }
            return;
        }
      } else if (node is dom.Text) {
        addTextBlock(text: node.text);
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

  Uint8List? _resolveImageBytes(String src, Map<String, EpubByteContentFile>? images) {
    if (images == null || images.isEmpty) return null;
    var normalized = src.replaceAll('\\', '/');
    normalized = normalized.replaceAll('../', '');
    final keyFragment = normalized.split('/').last;
    for (final entry in images.entries) {
      final key = entry.key.replaceAll('\\', '/');
      if (key.endsWith(keyFragment)) {
        final content = entry.value;
        final data = content.Content;
        if (data != null) {
          return Uint8List.fromList(data);
        }
      }
    }
    return null;
  }

}

class _DocumentExtractionResult {
  const _DocumentExtractionResult({
    required this.blocks,
    required this.chapters,
  });

  final List<DocumentBlock> blocks;
  final List<_ChapterEntry> chapters;
}

class _ChapterEntry {
  const _ChapterEntry({required this.index, required this.title});

  final int index;
  final String title;
}

class _PageMetrics {
  const _PageMetrics({
    required this.maxWidth,
    required this.maxHeight,
    required this.baseTextStyle,
    required this.textHeightBehavior,
    required this.textScaler,
  });

  final double maxWidth;
  final double maxHeight;
  final TextStyle baseTextStyle;
  final TextHeightBehavior textHeightBehavior;
  final TextScaler textScaler;
}

class _PageContentView extends StatelessWidget {
  const _PageContentView({
    required this.content,
    required this.maxWidth,
    required this.maxHeight,
    required this.textHeightBehavior,
    required this.textScaler,
  });

  final PageContent content;
  final double maxWidth;
  final double maxHeight;
  final TextHeightBehavior textHeightBehavior;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    
    for (final block in content.blocks) {
      if (block.spacingBefore > 0) {
        children.add(SizedBox(height: block.spacingBefore));
      }
      
      if (block is TextPageBlock) {
        children.add(
          Text(
            block.text,
            style: block.style,
            textAlign: block.textAlign,
            softWrap: true,
            textHeightBehavior: textHeightBehavior,
            textScaler: textScaler,
          ),
        );
      } else if (block is ImagePageBlock) {
        children.add(
          SizedBox(
            height: block.height,
            width: maxWidth,
            child: material.Image.memory(
              block.bytes,
              fit: BoxFit.contain,
            ),
          ),
        );
      }
      
      if (block.spacingAfter > 0) {
        children.add(SizedBox(height: block.spacingAfter));
      }
    }

    // No scroll view - pagination engine should prevent overflow
    // Make page content ignore pointer events so taps pass through to parent GestureDetector
    return IgnorePointer(
      child: SizedBox(
        width: maxWidth,
        height: maxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
