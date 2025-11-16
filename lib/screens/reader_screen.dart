import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:epubx/epubx.dart';
import 'package:flutter/gestures.dart' show PointerDownEvent, kPrimaryButton, kTouchSlop;
import 'package:flutter/material.dart' as material;
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:image/image.dart' as img show decodeImage;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:memoreader/l10n/app_localizations.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import '../services/enhanced_summary_service.dart';
import '../services/summary_config_service.dart';
import '../services/settings_service.dart';
import '../services/summary_database_service.dart';
import '../services/app_state_service.dart';
import '../services/prompt_config_service.dart';
import '../utils/html_text_extractor.dart';
import 'reader/document_model.dart';
import 'reader/line_metrics_pagination_engine.dart';
import 'reader/pagination_cache.dart';
import 'reader/tap_zones.dart';
import 'reader/reader_menu.dart';
import 'reader/navigation_helper.dart';
import 'routes.dart';
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
  final AppStateService _appStateService = AppStateService();
  
  double _horizontalPadding = _defaultHorizontalPadding; // Will be loaded from settings
  double _verticalPadding = _defaultVerticalPadding; // Will be loaded from settings

  Size? _lastActualSize;

  EpubBook? _epubBook;
  List<DocumentBlock> _docBlocks = [];
  List<_ChapterEntry> _chapterEntries = [];

  LineMetricsPaginationEngine? _engine;
  final SummaryDatabaseService _summaryDatabase = SummaryDatabaseService();

  int _currentPageIndex = 0;
  int _totalPages = 0;
  double _progress = 0;
  int _totalCharacterCount = 0;
  int _currentCharacterIndex = 0;

  bool _isLoading = true;
  String? _errorMessage;

  bool _showProgressBar = false;
  double _fontSize = 18.0;

  ReadingProgress? _savedProgress;
  Timer? _progressDebounce;
  bool _hasActiveSelection = false;
  bool _isProcessingSelection = false;
  VoidCallback? _clearSelectionCallback;
  DateTime? _lastSelectionChangeTimestamp;
  String? _selectionActionLabel;
  String? _selectionActionPrompt;
  Locale? _lastLocale;
  int? _activeTapPointer;
  Offset? _activeTapDownPosition;
  bool _activeTapExceededSlop = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSummaryService();
    _loadVerticalPadding();
    _loadBook();
    unawaited(_appStateService.setLastOpenedBook(widget.book.id));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_lastLocale != locale) {
      _lastLocale = locale;
      _loadSelectionActionConfig();
    }
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

  Future<void> _loadSelectionActionConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final promptService = PromptConfigService(prefs);
      final language = Localizations.localeOf(context).languageCode;
      final label = promptService.getTextActionLabel(language);
      final prompt = promptService.getTextActionPrompt(language);
      if (!mounted) return;
      setState(() {
        _selectionActionLabel = label;
        _selectionActionPrompt = prompt;
      });
    } catch (e) {
      debugPrint('Failed to load selection action config: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _engine?.removeListener(_handleEngineUpdate);
    _pageController.dispose();
    _progressDebounce?.cancel();
    
    // Always update reading stop when leaving reader (all interruptions are tracked)
    _updateLastReadingStopOnExit();
    
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!_isLoading && mounted) {
      _scheduleRepagination(retainCurrentPage: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final shouldPersistProgress = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden;

    if (shouldPersistProgress) {
      final page = _engine?.getPage(_currentPageIndex);
      if (page != null) {
        unawaited(_saveProgress(page));
        // Update reading stop when app goes to background
        unawaited(_updateLastReadingStopOnExit());
      }
      unawaited(_appStateService.setLastOpenedBook(widget.book.id));
      return;
    }

    if (state == AppLifecycleState.resumed && !_isLoading && mounted) {
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
        _totalCharacterCount = extraction.totalCharacters;
        _savedProgress = progress;
        _isLoading = false;
      });

      final initialCharIndex = progress?.currentCharacterIndex ?? 0;
      // When no character information is stored we simply restart from the
      // beginning, letting the first pagination pass reinitialize the data.
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
      int? targetCharIndex;
      if (retainCurrentPage) {
        final currentPage = _engine?.getPage(_currentPageIndex);
        targetCharIndex =
            currentPage?.startCharIndex ?? _savedProgress?.currentCharacterIndex;
      } else if (initialCharIndex != null) {
        targetCharIndex = initialCharIndex;
      }

      targetCharIndex ??= _savedProgress?.currentCharacterIndex ?? 0;
      targetCharIndex = math.max(0, targetCharIndex);

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

    final initialPage = engine.getPage(targetPageIndex);
    final updatedTotalChars = math.max(_totalCharacterCount, engine.totalCharacters);

    setState(() {
      _engine = engine;
      _totalPages = engine.estimatedTotalPages;
      _currentPageIndex = targetPageIndex;
      _totalCharacterCount = updatedTotalChars;
      if (initialPage != null) {
        _currentCharacterIndex = initialPage.startCharIndex;
        _progress =
            _calculateProgressForPage(initialPage, totalChars: updatedTotalChars);
      } else {
        _currentCharacterIndex = 0;
        _progress = 0;
      }
      _showProgressBar = false;
    });

    _resetPagerToCurrent();

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

  bool _shouldTrackPointer(PointerDownEvent event) {
    switch (event.kind) {
      case PointerDeviceKind.mouse:
        return (event.buttons & kPrimaryButton) != 0;
      case PointerDeviceKind.touch:
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
      case PointerDeviceKind.unknown:
        return true;
      default:
        return false;
    }
  }

  void _resetTapTracking() {
    _activeTapPointer = null;
    _activeTapDownPosition = null;
    _activeTapExceededSlop = false;
  }

  void _handleTapUp(TapUpDetails details) {
    // Trigger page/menu/progress actions when the tap is released to avoid
    // accidental activations from other gestures while keeping taps snappy.
    if (_hasActiveSelection) {
      final lastSelectionChange = _lastSelectionChangeTimestamp;
      final shouldDeferClearing = lastSelectionChange != null &&
          DateTime.now().difference(lastSelectionChange) <
              const Duration(milliseconds: 250);

      if (shouldDeferClearing) {
        // Ignore the tap that ends an active selection gesture so the
        // highlight stays visible and the context menu can be used.
        return;
      }

      // Clear selection by deselecting
      setState(() {
        _hasActiveSelection = false;
        _lastSelectionChangeTimestamp = null;
      });
      _clearSelectionCallback?.call();
      _clearSelectionCallback = null;
      return;
    }

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
        unawaited(_goToNextPage());
        break;
      case ReaderTapAction.previousPage:
        _goToPreviousPage();
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

  void _handleSelectionChanged(bool hasSelection, VoidCallback clearSelection) {
    if (hasSelection) {
      _resetTapTracking();
      _clearSelectionCallback = clearSelection;
      _lastSelectionChangeTimestamp = DateTime.now();
    } else {
      _clearSelectionCallback = null;
      _lastSelectionChangeTimestamp = null;
    }

    if (_hasActiveSelection != hasSelection) {
      setState(() {
        _hasActiveSelection = hasSelection;
      });
    }
  }

  Future<void> _saveProgress(PageContent page) async {
    try {
      final pageProgress = _calculateProgressForPage(page);
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentCharacterIndex: page.startCharIndex,
        progress: pageProgress,
        lastRead: DateTime.now(),
      );
      await _bookService.saveReadingProgress(progress);
      _savedProgress = progress;
      // Note: updateLastReadingStop is NOT called here anymore
      // It's only called when actually leaving the reader screen
    } catch (_) {
      // Saving progress is best-effort; ignore failures.
    }
  }

  /// Update the last reading stop position when leaving the reader
  /// This is called when the user actually stops reading (not just saving progress)
  Future<void> _updateLastReadingStopOnExit() async {
    try {
      final page = _engine?.getPage(_currentPageIndex);
      if (page == null) return;

      final chunkIndex = _summaryService != null
          ? _summaryService!.estimateChunkIndexForCharacter(page.startCharIndex ?? 0)
          : EnhancedSummaryService.computeChunkIndexForCharacterStatic(page.startCharIndex ?? 0);
      
      unawaited(_summaryDatabase.updateLastReadingStop(
        widget.book.id,
        chunkIndex: chunkIndex,
        characterIndex: page.startCharIndex,
      ));
      if (_summaryService != null) {
        unawaited(_summaryService!.updateLastReadingStop(
          widget.book.id,
          chunkIndex: chunkIndex,
          characterIndex: page.startCharIndex,
        ));
      }
    } catch (_) {
      // Updating reading stop is best-effort; ignore failures.
    }
  }

  void _changeFontSize(double value) {
    setState(() {
      _fontSize = value;
    });
    _scheduleRepagination(retainCurrentPage: true);
  }

  Future<bool> _goToNextPage({bool resetPager = true}) async {
    final engine = _engine;
    if (engine == null) {
      return false;
    }
    if (!engine.hasNextPage(_currentPageIndex)) {
      return false;
    }

    await engine.ensureWindow(_currentPageIndex + 1, radius: 1);
    if (!mounted) {
      return false;
    }

    setState(() {
      _currentPageIndex++;
      _showProgressBar = false;
      final page = engine.getPage(_currentPageIndex);
      if (page != null) {
        _currentCharacterIndex = page.startCharIndex;
        _progress = _calculateProgressForPage(page);
      } else {
        _currentCharacterIndex = 0;
        _progress = 0;
      }
    });

    unawaited(engine.ensureWindow(_currentPageIndex, radius: 1));
    unawaited(engine.startBackgroundPagination());
    _scheduleProgressSave();

    if (resetPager) {
      _resetPagerToCurrent();
    }

    return true;
  }

  bool _goToPreviousPage({bool resetPager = true}) {
    if (_currentPageIndex <= 0) {
      if (_showProgressBar) {
        setState(() {
          _showProgressBar = false;
        });
      }
      return false;
    }

    setState(() {
      _currentPageIndex--;
      _showProgressBar = false;
      final page = _engine?.getPage(_currentPageIndex);
      if (page != null) {
        _currentCharacterIndex = page.startCharIndex;
        _progress = _calculateProgressForPage(page);
      } else {
        _currentCharacterIndex = 0;
        _progress = 0;
      }
    });

    unawaited(_engine?.ensureWindow(_currentPageIndex, radius: 1));
    unawaited(_engine?.startBackgroundPagination());
    _scheduleProgressSave();

    if (resetPager) {
      _resetPagerToCurrent();
    }

    return true;
  }

  void _resetPagerToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(1);
      }
    });
  }

  double _calculateProgressForPage(PageContent? page, {int? totalChars}) {
    final effectiveTotal = totalChars ?? _totalCharacterCount;
    if (page == null || effectiveTotal <= 0) {
      return 0;
    }
    final completed = math.min(
      effectiveTotal,
      math.max(0, page.endCharIndex + 1),
    );
    return completed / effectiveTotal;
  }

  Future<void> _showGoToPercentageDialog() async {
    if (_totalCharacterCount <= 0) {
      return;
    }

    final controller = TextEditingController(
      text: (_progress * 100).clamp(0, 100).toStringAsFixed(1),
    );
    String? errorText;

    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            void submit() {
              final input = controller.text.trim().replaceAll(',', '.');
              final value = double.tryParse(input);
              if (value == null) {
                setState(() {
                  errorText = 'Veuillez entrer un nombre valide';
                });
                return;
              }
              if (value < 0 || value > 100) {
                setState(() {
                  errorText = 'Entrez une valeur entre 0 et 100';
                });
                return;
              }
              Navigator.of(context).pop(value);
            }

            return AlertDialog(
              title: const Text('Aller à un pourcentage'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Pourcentage',
                  suffixText: '%',
                  errorText: errorText,
                ),
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
                TextButton(
                  onPressed: submit,
                  child: const Text('Aller'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    if (result != null) {
      _jumpToPercentage(result);
    }
  }

  void _jumpToPercentage(double percentage) {
    final totalChars = _totalCharacterCount;
    if (totalChars <= 0) {
      return;
    }

    if (totalChars == 1) {
      _scheduleRepagination(initialCharIndex: 0);
      return;
    }

    final normalized = percentage.clamp(0.0, 100.0);
    final target = (normalized / 100.0) * (totalChars - 1);
    final rounded = target.round();
    final clamped = rounded < 0
        ? 0
        : (rounded >= totalChars ? totalChars - 1 : rounded);
    _scheduleRepagination(initialCharIndex: clamped);
  }

  void _handlePageChanged(int pageIndex) {
    if (pageIndex == 1) return;

    if (pageIndex == 2) {
      unawaited(
        _goToNextPage(resetPager: false).whenComplete(_resetPagerToCurrent),
      );
    } else if (pageIndex == 0) {
      _goToPreviousPage(resetPager: false);
      _resetPagerToCurrent();
    } else {
      _resetPagerToCurrent();
    }
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
            physics:
                _hasActiveSelection ? const NeverScrollableScrollPhysics() : null,
            itemBuilder: (context, index) => pages[index],
          ),
          // GestureDetector that covers the entire screen to catch taps
          // Actions are dispatched on tap up so the entire single-tap gesture
          // completes before navigation/menu toggles run.
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (_activeTapPointer != null) return;
                if (!_shouldTrackPointer(event)) return;
                _activeTapPointer = event.pointer;
                _activeTapDownPosition = event.position;
                _activeTapExceededSlop = false;
              },
              onPointerMove: (event) {
                if (event.pointer != _activeTapPointer) return;
                final downPosition = _activeTapDownPosition;
                if (downPosition == null) return;
                if (!_activeTapExceededSlop &&
                    (event.position - downPosition).distance > kTouchSlop) {
                  _activeTapExceededSlop = true;
                }
              },
              onPointerCancel: (event) {
                if (event.pointer == _activeTapPointer) {
                  _resetTapTracking();
                }
              },
              onPointerUp: (event) {
                if (event.pointer == _activeTapPointer) {
                  if (!_activeTapExceededSlop) {
                    _handleTapUp(
                      TapUpDetails(
                        globalPosition: event.position,
                        localPosition: event.localPosition,
                        kind: event.kind,
                      ),
                    );
                  }
                  _resetTapTracking();
                }
              },
              child: const SizedBox.expand(),
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

    final l10n = AppLocalizations.of(context);
    final defaultActionLabel = l10n?.textSelectionDefaultLabel ?? 'Translate';
    final actionLabel = (_selectionActionLabel ?? defaultActionLabel).trim().isEmpty
        ? defaultActionLabel
        : _selectionActionLabel!;

    // Center the page content with proper constraints
    return SizedBox.expand(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _horizontalPadding,
          vertical: _verticalPadding,
        ),
        child: Align(
          alignment: Alignment.center,
          child: _PageContentView(
            content: page,
            maxWidth: metrics.maxWidth,
            maxHeight: metrics.maxHeight,
            textHeightBehavior: metrics.textHeightBehavior,
            textScaler: metrics.textScaler,
            actionLabel: actionLabel,
            onSelectionAction: _handleSelectionAction,
            onSelectionChanged: _handleSelectionChanged,
            isProcessingAction: _isProcessingSelection,
          ),
        ),
      ),
    );
  }

  void _openReadingMenu() {
    unawaited(showReaderMenu(
      context: context,
      fontSize: _fontSize,
      onFontSizeChanged: _changeFontSize,
      hasChapters: _chapterEntries.isNotEmpty,
      onGoToChapter: _showChapterSelector,
      onGoToPercentage: _showGoToPercentageDialog,
      onShowSummaryFromBeginning: () => _openSummary(SummaryType.fromBeginning),
      onShowSummarySinceLastTime: () => _openSummary(SummaryType.sinceLastTime),
      onShowCharactersSummary: () => _openSummary(SummaryType.characters),
      onReturnToLibrary: _returnToLibrary,
    ));
  }

  Future<void> _returnToLibrary() {
    return returnToLibrary(
      context,
      openLibrary: () => Navigator.of(context).pushReplacementNamed(libraryRoute),
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

  Future<bool> _ensureSummaryServiceReady() async {
    if (_summaryService != null) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    final l10n = AppLocalizations.of(context)!;
    final shouldGoToSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.summaryConfigurationRequiredTitle),
        content: Text(l10n.summaryConfigurationRequiredBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.settings),
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
      await _initializeSummaryService();
      await _loadVerticalPadding();
      await _loadSelectionActionConfig();
      if (mounted) {
        _scheduleRepagination(retainCurrentPage: true);
      }
    }

    return _summaryService != null;
  }

  void _handleEngineUpdate() {
    if (!mounted || _engine == null) return;
    final engine = _engine!;
    final estimated = engine.estimatedTotalPages;
    final updatedTotalChars = math.max(_totalCharacterCount, engine.totalCharacters);
    final currentPage = engine.getPage(_currentPageIndex);

    setState(() {
      _totalPages = estimated;
      _totalCharacterCount = updatedTotalChars;
      if (currentPage != null) {
        _currentCharacterIndex = currentPage.startCharIndex;
        _progress =
            _calculateProgressForPage(currentPage, totalChars: updatedTotalChars);
      }
    });
  }

  void _openSummary(SummaryType summaryType) async {
    if (_engine == null) return;
    final currentPage = _engine!.getPage(_currentPageIndex);
    if (currentPage == null) return;

    if (!await _ensureSummaryServiceReady()) {
      return;
    }

    final progress = ReadingProgress(
      bookId: widget.book.id,
      currentCharacterIndex: currentPage.startCharIndex,
      progress: _calculateProgressForPage(currentPage),
      lastRead: DateTime.now(),
    );

    // Build an engine-aligned full text to guarantee index consistency
    final engineTextBuffer = StringBuffer();
    for (final block in _docBlocks) {
      if (block is TextDocumentBlock) {
        engineTextBuffer.write(block.text);
      } else if (block is ImageDocumentBlock) {
        // Engine counts images as a single character in totalCharacters.
        // Use one placeholder character to preserve indices alignment.
        engineTextBuffer.write('\uFFFC');
      }
    }
    final engineFullText = engineTextBuffer.toString();

    // Record interruption when going to summaries (all interruptions are tracked)
    final page = _engine?.getPage(_currentPageIndex);
    if (page != null) {
      unawaited(_updateLastReadingStopOnExit());
    }
    
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SummaryScreen(
          book: widget.book,
          progress: progress,
          enhancedSummaryService: _summaryService!,
          summaryType: summaryType,
          engineFullText: engineFullText,
        ),
      ),
    );
  }

  Future<void> _handleSelectionAction(String selectedText) async {
    final trimmed = selectedText.trim();
    if (trimmed.isEmpty || _isProcessingSelection) {
      return;
    }

    if (!await _ensureSummaryServiceReady()) {
      return;
    }

    // Clear selection state
    setState(() {
      _isProcessingSelection = true;
      _hasActiveSelection = false;
      _lastSelectionChangeTimestamp = null;
    });

    final l10n = AppLocalizations.of(context)!;
    bool progressVisible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(l10n.textSelectionActionProcessing)),
          ],
        ),
      ),
    ).then((_) => progressVisible = false);

    try {
      final locale = Localizations.localeOf(context);
      final languageCode = locale.languageCode;
      final prefs = await SharedPreferences.getInstance();
      final promptService = PromptConfigService(prefs);
      final languageName = l10n.appLanguageName;

      final label = (_selectionActionLabel ??
              promptService.getTextActionLabel(languageCode))
          .trim()
          .isEmpty
          ? promptService.getTextActionLabel(languageCode)
          : (_selectionActionLabel ?? promptService.getTextActionLabel(languageCode));
      final promptTemplate = _selectionActionPrompt ??
          promptService.getTextActionPrompt(languageCode);

      if (mounted) {
        setState(() {
          _selectionActionLabel = label;
          _selectionActionPrompt = promptTemplate;
        });
      }

      final formattedPrompt = promptService.formatPrompt(
        promptTemplate,
        text: trimmed,
        languageName: languageName,
      );

      final response = await _summaryService!.runCustomPrompt(
        formattedPrompt,
        languageCode,
      );

      if (progressVisible && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        progressVisible = false;
      }

      if (!mounted) {
        return;
      }

      await _showSelectionResultDialog(
        originalText: trimmed,
        generatedText: response.trim(),
        actionLabel: label,
      );
    } catch (e, stack) {
      debugPrint('Error executing selection action: $e');
      debugPrint('$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.textSelectionActionError)),
        );
      }
    } finally {
      if (progressVisible && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        setState(() {
          _isProcessingSelection = false;
        });
      }
    }
  }

  Future<void> _showSelectionResultDialog({
    required String originalText,
    required String generatedText,
    required String actionLabel,
  }) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          actionLabel,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.textSelectionSelectedTextLabel,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    fit: FlexFit.loose,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(originalText),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.textSelectionActionResultLabel,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    fit: FlexFit.loose,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(generatedText),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

    final totalCharacters = _countTotalCharacters(blocks);

    return _DocumentExtractionResult(
      blocks: blocks,
      chapters: chapters,
      totalCharacters: totalCharacters,
    );
  }

  int _countTotalCharacters(List<DocumentBlock> blocks) {
    var total = 0;
    for (final block in blocks) {
      if (block is TextDocumentBlock) {
        total += block.text.length;
      } else if (block is ImageDocumentBlock) {
        total += 1;
      }
    }
    return total;
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
    required this.totalCharacters,
  });

  final List<DocumentBlock> blocks;
  final List<_ChapterEntry> chapters;
  final int totalCharacters;
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

class _PageContentView extends StatefulWidget {
  const _PageContentView({
    required this.content,
    required this.maxWidth,
    required this.maxHeight,
    required this.textHeightBehavior,
    required this.textScaler,
    required this.actionLabel,
    required this.onSelectionAction,
    required this.onSelectionChanged,
    required this.isProcessingAction,
  });

  final PageContent content;
  final double maxWidth;
  final double maxHeight;
  final TextHeightBehavior textHeightBehavior;
  final TextScaler textScaler;
  final String actionLabel;
  final ValueChanged<String>? onSelectionAction;
  final void Function(bool hasSelection, VoidCallback clearSelection)?
      onSelectionChanged;
  final bool isProcessingAction;

  @override
  State<_PageContentView> createState() => _PageContentViewState();
}

class _PageContentViewState extends State<_PageContentView> {
  String _selectedText = '';
  int _selectionGeneration = 0;

  void _clearSelection() {
    setState(() {
      _selectedText = '';
      _selectionGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    for (final block in widget.content.blocks) {
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
            textHeightBehavior: widget.textHeightBehavior,
            textScaler: widget.textScaler,
          ),
        );
      } else if (block is ImagePageBlock) {
        children.add(
          SizedBox(
            height: block.height,
            width: widget.maxWidth,
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

    return SizedBox(
      width: widget.maxWidth,
      height: widget.maxHeight,
      child: SelectionArea(
        key: ValueKey(_selectionGeneration),
        contextMenuBuilder: (context, delegate) {
          final items = delegate.contextMenuButtonItems.toList();
          final trimmedText = _selectedText.trim();
          if (trimmedText.isNotEmpty && widget.onSelectionAction != null && !widget.isProcessingAction) {
            // Insérer l'action personnalisée au début du menu, au même niveau que "Copier" et "Tout sélectionner"
            items.insert(0,
              ContextMenuButtonItem(
                onPressed: () {
                  delegate.hideToolbar();
                  widget.onSelectionAction?.call(trimmedText);
                  _clearSelection();
                },
                label: widget.actionLabel,
              ),
            );
          }
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: delegate.contextMenuAnchors,
            buttonItems: items,
          );
        },
        onSelectionChanged: (selection) {
          // Get plain text from selection - selection is a SelectedContent?
          final selected = selection?.plainText ?? '';
          setState(() {
            _selectedText = selected;
          });
          final hasSelection = selected.trim().isNotEmpty;
          widget.onSelectionChanged?.call(hasSelection, _clearSelection);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: children,
        ),
      ),
    );
  }
}
