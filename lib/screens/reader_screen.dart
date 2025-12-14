import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;
import 'package:epubx/epubx.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show PointerCancelEvent, PointerDownEvent, PointerMoveEvent, PointerUpEvent, kPrimaryButton, kTouchSlop;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
import '../utils/css_resolver.dart';
import 'reader/document_model.dart';
import 'reader/line_metrics_pagination_engine.dart';
import 'reader/page_content_view.dart';
import 'reader/tap_zones.dart';
import 'reader/reader_menu.dart';
import 'reader/navigation_helper.dart';
import 'reader/selection_warmup.dart';
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
  static const double _defaultReaderFontSize = 18.0;

  final BookService _bookService = BookService();
  final SettingsService _settingsService = SettingsService();
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
  int? _lastVisibleCharacterIndex;

  bool _isLoading = true;
  String? _errorMessage;

  bool _showProgressBar = false;
  bool _isNavigating = false; // Track when navigation/repagination is in progress
  int? _navigatingToChapterIndex; // Track which chapter is being navigated to
  NavigatorState? _chapterDialogNavigator; // Reference to chapter dialog's Navigator for closing
  VoidCallback? _chapterDialogRebuildCallback; // Callback to trigger dialog rebuild
  double _fontScale = 1.0; // Font scale multiplier (1.0 = normal)

  ReadingProgress? _savedProgress;
  Timer? _progressDebounce;
  // Text selection state management
  // When a selection is active, tap-up events clear the selection instead of triggering actions
  bool _hasActiveSelection = false;
  bool _isProcessingSelection = false;
  VoidCallback? _clearSelectionCallback; // Callback to clear selection programmatically
  DateTime? _lastSelectionChangeTimestamp; // Used to defer clearing selection (allow context menu)
  int? _selectionOwnerPointer; // Pointer that initiated the current selection
  String? _selectionActionLabel;
  String? _selectionActionPrompt;
  Locale? _lastLocale;
  int? _activeTapPointer;
  Offset? _activeTapDownPosition;
  DateTime? _activeTapDownTime;
  bool _activeTapExceededSlop = false;
  static const Duration _longPressThreshold = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Enable wake lock to keep screen on while reading
    WakelockPlus.enable();
    _initializeSummaryService();
    _loadVerticalPadding();
    _loadFontScale();
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
    
    // Disable wake lock when leaving reader screen
    WakelockPlus.disable();
    
    // Always update reading stop when leaving reader (all interruptions are tracked)
    _updateLastReadingStopOnExit();
    
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    
    // Only schedule repagination if the screen size actually changed significantly.
    // This prevents unnecessary expensive repagination when the keyboard opens/closes
    // (which changes viewInsets but often not the available window size for our reader)
    if (!_isLoading && mounted && _lastActualSize != null) {
      final newSize = MediaQuery.of(context).size;
      // Check if width or height changed by more than a small threshold
      if ((newSize.width - _lastActualSize!.width).abs() > 1.0 || 
          (newSize.height - _lastActualSize!.height).abs() > 1.0) {
        _scheduleRepagination(retainCurrentPage: true);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final shouldPersistProgress = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden;

    if (shouldPersistProgress) {
      // Disable wake lock when app goes to background to save battery
      WakelockPlus.disable();
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
      // Re-enable wake lock when app comes back to foreground
      WakelockPlus.enable();
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
        _lastVisibleCharacterIndex =
            progress?.lastVisibleCharacterIndex ?? progress?.currentCharacterIndex;
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

    // Navigation state should already be set when chapter was selected
    // If not, set it now (for cases where pagination is triggered from elsewhere)
    if (mounted && !_isNavigating) {
      setState(() {
        _isNavigating = true;
      });
      // Trigger dialog rebuild to start pulsating animation
      _chapterDialogRebuildCallback?.call();
    } else if (mounted) {
      // State already set, just trigger rebuild to ensure pulsating continues
      _chapterDialogRebuildCallback?.call();
    }

    try {
      Size? sizeForMetrics = actualSize ?? _lastActualSize;
      if (!mounted) {
        _clearNavigatingState();
        return;
      }
      sizeForMetrics ??= MediaQuery.of(context).size;
      final baseMetrics = _computePageMetrics(context, sizeForMetrics);
      final metrics = _adjustForUserPadding(baseMetrics);

      final previousEngine = _engine;
      previousEngine?.removeListener(_handleEngineUpdate);

      if (!mounted) {
        _clearNavigatingState();
        return;
      }
      final engine = await LineMetricsPaginationEngine.create(
        bookId: widget.book.id,
        blocks: _docBlocks,
        baseTextStyle: metrics.baseTextStyle,
        maxWidth: metrics.maxWidth,
        maxHeight: metrics.maxHeight,
        textHeightBehavior: metrics.textHeightBehavior,
        textScaler: metrics.textScaler,
        cacheManager: null,
        viewportInsetBottom: metrics.viewportBottomInset,
      );

      if (!mounted) {
        _clearNavigatingState();
        return;
      }
      final targetPageIndex =
          await engine.ensurePageForCharacter(startCharIndex, windowRadius: 1);
      engine.addListener(_handleEngineUpdate);
      unawaited(engine.ensureWindow(targetPageIndex, radius: 1));
      unawaited(engine.startBackgroundPagination());

      if (!mounted) {
        _clearNavigatingState();
        return;
      }
      final initialPage = engine.getPage(targetPageIndex);
      final updatedTotalChars = math.max(_totalCharacterCount, engine.totalCharacters);

      // Use SchedulerBinding to ensure we're not in a build phase
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _engine = engine;
            _totalPages = engine.estimatedTotalPages;
            _currentPageIndex = targetPageIndex;
            _totalCharacterCount = updatedTotalChars;
            if (initialPage != null) {
              _currentCharacterIndex = initialPage.startCharIndex;
              _progress =
                  _calculateProgressForPage(initialPage, totalChars: updatedTotalChars);
              _lastVisibleCharacterIndex = initialPage.endCharIndex;
              _logLastVisibleWords(initialPage);
            } else {
              _currentCharacterIndex = 0;
              _progress = 0;
              _lastVisibleCharacterIndex = null;
            }
            _showProgressBar = false;
            _isNavigating = false; // Clear navigating state after UI update
            _navigatingToChapterIndex = null; // Clear selected chapter index
          });

          if (mounted) {
            _resetPagerToCurrent();
            _scheduleProgressSave();
            // Close chapter dialog after navigation completes
            _closeChapterDialog();
          }
        });
      }
    } catch (e) {
      // Clear navigating state on error
      _clearNavigatingState();
      // Close dialog on error
      _closeChapterDialog();
      rethrow;
    }
  }

  void _clearNavigatingState() {
    if (mounted) {
      setState(() {
        _isNavigating = false;
        _navigatingToChapterIndex = null;
      });
    }
  }

  void _closeChapterDialog() {
    if (_chapterDialogNavigator != null && _chapterDialogNavigator!.canPop()) {
      _chapterDialogNavigator!.pop();
    }
    _chapterDialogNavigator = null;
    _chapterDialogRebuildCallback = null;
    _navigatingToChapterIndex = null;
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
    final bottomSafeInset =
        math.max(mediaQuery.padding.bottom, mediaQuery.viewPadding.bottom);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final viewportInsetBottom = math.max(bottomSafeInset, keyboardInset);
    final maxWidth = math.max(120.0, size.width - systemHorizontalPadding);
    final maxHeight = math.max(160.0, size.height - systemVerticalPadding);

    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.onSurface;
    // Use maybeOf to avoid error if DefaultTextHeightBehavior is not in widget tree
    // Provide default TextHeightBehavior if none is found
    final textHeightBehavior = DefaultTextHeightBehavior.maybeOf(context) ??
        const TextHeightBehavior();
    final baseStyle = theme.textTheme.bodyMedium?.copyWith(
          fontSize: _effectiveFontSize,
          height: 1.6,
          color: baseColor,
        ) ??
        TextStyle(
          fontSize: _effectiveFontSize,
          height: 1.6,
          color: baseColor,
        );

    return _PageMetrics(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      baseTextStyle: baseStyle,
      textHeightBehavior: textHeightBehavior,
      textScaler: MediaQuery.textScalerOf(context),
      viewportBottomInset: viewportInsetBottom,
    );
  }

_PageMetrics _adjustForUserPadding(_PageMetrics metrics) {
    final adjustedWidth =
        math.max(120.0, metrics.maxWidth - _horizontalPadding * 2);
    final adjustedHeight =
        math.max(160.0, metrics.maxHeight - _verticalPadding * 2);
    final adjustedInset =
        math.max(0.0, metrics.viewportBottomInset - _verticalPadding);
    return _PageMetrics(
      maxWidth: adjustedWidth,
      maxHeight: adjustedHeight,
      baseTextStyle: metrics.baseTextStyle,
      textHeightBehavior: metrics.textHeightBehavior,
      textScaler: metrics.textScaler,
      viewportBottomInset: adjustedInset,
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

  void _logLastVisibleWords(PageContent page) {
    if (!kDebugMode) {
      return;
    }
    final words = _extractLastWordsFromPage(page, 10);
    if (words.isEmpty) {
      return;
    }
    debugPrint('[ReaderScreen] Last visible words: $words');
  }

  String _extractLastWordsFromPage(PageContent page, int count) {
    final buffer = StringBuffer();
    for (final block in page.blocks) {
      if (block is TextPageBlock) {
        buffer.write(block.text);
        buffer.write(' ');
      }
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      return '';
    }
    final wordList = text.split(RegExp(r'\s+'));
    final start = math.max(0, wordList.length - count);
    return wordList.sublist(start).join(' ');
  }

  void _handleTapUp(TapUpDetails details) {
    final size = MediaQuery.of(context).size;
    final action = determineTapAction(details.globalPosition, size);
    debugPrint('[ReaderScreen] TapUp -> $action at ${details.globalPosition}');

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

  void _resetTapTracking() {
    _activeTapPointer = null;
    _activeTapDownPosition = null;
    _activeTapDownTime = null;
    _activeTapExceededSlop = false;
  }

  void _handlePointerDown(PointerDownEvent event) {
    // READER MODE ONLY: This method is only called when selection is NOT active
    // CRITICAL: Don't track anything here - let SelectableText's gesture recognizer
    // win the gesture arena for taps and long presses. We'll only track if it becomes
    // a clear swipe gesture (detected in pointer move).
    if (!_shouldTrackPointer(event) || _activeTapPointer != null) {
      return;
    }
    // Store minimal info but don't interfere with gesture detection
    _activeTapPointer = event.pointer;
    _activeTapDownPosition = event.position;
    _activeTapDownTime = DateTime.now();
    _activeTapExceededSlop = false;
    // Don't do anything else - let SelectableText handle the gesture
  }

  void _handlePointerMove(PointerMoveEvent event) {
    // READER MODE ONLY: This method is only called when selection is NOT active
    // Only track if this is clearly a horizontal swipe gesture (page navigation)
    // Vertical movement or small movements are ignored to allow text selection
    if (event.pointer != _activeTapPointer) return;
    final downPosition = _activeTapDownPosition;
    if (downPosition == null) return;
    
    final delta = event.position - downPosition;
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    
    // Only treat as swipe if:
    // 1. Significant horizontal movement (page swipe)
    // 2. Horizontal movement is greater than vertical (not text selection drag)
    // This allows SelectableText to handle vertical text selection without interference
    if (!_activeTapExceededSlop && 
        horizontalDistance > kTouchSlop * 3 && 
        horizontalDistance > verticalDistance * 1.5) {
      _activeTapExceededSlop = true;
      debugPrint(
          '[ReaderScreen] Reader mode: Horizontal swipe detected (h=$horizontalDistance, v=$verticalDistance) -> page navigation');
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activeTapPointer) {
      debugPrint('[ReaderScreen] Pointer cancel (${event.pointer})');
      _resetTapTracking();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    // READER MODE ONLY: This method is only called when selection is NOT active
    if (event.pointer != _activeTapPointer) {
      return;
    }

    final now = DateTime.now();
    final pressDuration =
        _activeTapDownTime != null ? now.difference(_activeTapDownTime!) : null;
    debugPrint(
        '[ReaderScreen] Reader mode: Pointer up (${event.pointer}) duration=${pressDuration?.inMilliseconds}ms slopExceeded=$_activeTapExceededSlop');

    // Long press detection: if user long-pressed, don't handle as tap
    // The text selection system will handle it
    if (pressDuration != null && pressDuration >= _longPressThreshold) {
      debugPrint('[ReaderScreen] Reader mode: Long press detected; allowing text selection to handle');
      _resetTapTracking();
      return;
    }

    // If user dragged, don't handle as tap
    if (_activeTapExceededSlop) {
      _resetTapTracking();
      return;
    }

    // Handle as a tap for reader navigation
    _handleTapIfAllowed(TapUpDetails(
      globalPosition: event.position,
      localPosition: event.localPosition,
      kind: event.kind,
    ));

    _resetTapTracking();
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

  void _handleTapIfAllowed(TapUpDetails details) {
    // READER MODE ONLY: This method is only called when selection is NOT active
    // Just handle the tap for navigation
    _handleTapUp(details);
  }
  void _handleSelectionChanged(bool hasSelection, VoidCallback clearSelection) {
    // STATE TRANSITION: Switch between reader mode and selection mode
    if (hasSelection) {
      // Entering SELECTION MODE: disable all reader gestures
      _clearSelectionCallback = clearSelection;
      _lastSelectionChangeTimestamp = DateTime.now();
      // Clear any active reader gesture tracking
      _resetTapTracking();
      debugPrint('[ReaderScreen] STATE: Entering SELECTION MODE - reader gestures disabled');
    } else {
      // Entering READER MODE: re-enable reader gestures
      _clearSelectionCallback = null;
      _lastSelectionChangeTimestamp = null;
      _selectionOwnerPointer = null;
      _resetTapTracking();
      debugPrint('[ReaderScreen] STATE: Entering READER MODE - reader gestures enabled');
    }

    if (_hasActiveSelection != hasSelection) {
      setState(() {
        _hasActiveSelection = hasSelection;
      });
    }
  }

  void _clearSelectionState() {
    setState(() {
      _hasActiveSelection = false;
      _lastSelectionChangeTimestamp = null;
      _selectionOwnerPointer = null;
    });
    _clearSelectionCallback?.call();
    _clearSelectionCallback = null;
  }

  Future<void> _saveProgress(PageContent page) async {
    try {
      final pageProgress = _calculateProgressForPage(page);
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentCharacterIndex: page.startCharIndex,
        lastVisibleCharacterIndex: page.endCharIndex,
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

  double get _effectiveFontSize =>
      _defaultReaderFontSize * _fontScale;

  Future<void> _loadFontScale() async {
    final storedScale = await _settingsService.getReaderFontScale();
    if (mounted) {
      setState(() {
        _fontScale = storedScale;
      });
      if (_docBlocks.isNotEmpty) {
        _scheduleRepagination(retainCurrentPage: true);
      }
    }
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
        _lastVisibleCharacterIndex = page.endCharIndex;
        _logLastVisibleWords(page);
      } else {
        _currentCharacterIndex = 0;
        _progress = 0;
        _lastVisibleCharacterIndex = null;
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
        _lastVisibleCharacterIndex = page.endCharIndex;
        _logLastVisibleWords(page);
      } else {
        _currentCharacterIndex = 0;
        _progress = 0;
        _lastVisibleCharacterIndex = null;
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
    final focusNode = FocusNode();
    String? errorText;

    // Request focus after dialog is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (focusNode.canRequestFocus) {
        focusNode.requestFocus();
      }
    });

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
                focusNode: focusNode,
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
    focusNode.dispose();

    if (result != null && mounted) {
      // Use SchedulerBinding to ensure dialog is fully closed and widget tree is stable
      // before triggering repagination
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _jumpToPercentage(result);
        }
      });
    }
  }

  void _jumpToPercentage(double percentage) {
    if (!mounted) return;
    
    try {
      // Safety check: ensure engine and book data are loaded
      if (_engine == null || _totalCharacterCount <= 0) {
        debugPrint('[ReaderScreen] Cannot jump to percentage: engine not ready');
        return;
      }

      final totalChars = _totalCharacterCount;
      if (totalChars <= 0) {
        return;
      }

      if (totalChars == 1) {
        _scheduleRepagination(initialCharIndex: 0);
        return;
      }

      final normalized = percentage.clamp(0.0, 100.0);
      // Calculate target character index
      final target = (normalized / 100.0) * (totalChars - 1);
      final rounded = target.round();
      final clamped = rounded.clamp(0, totalChars - 1);
      
      debugPrint('[ReaderScreen] Jumping to $normalized% -> char index $clamped');
      _scheduleRepagination(initialCharIndex: clamped);
    } catch (e, stack) {
      debugPrint('[ReaderScreen] Error during jump to percentage: $e');
      debugPrint('$stack');
      // Adding a safe fallback or simply ignoring the failed jump
    }
  }

  void _handlePageChanged(int pageIndex) {
    if (pageIndex == 1) return;

    // Any page change (tap or swipe) clears active selection.
    _clearSelectionState();
    debugPrint('[ReaderScreen] PageView changed to index=$pageIndex');

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

    // Wrap with SelectionWarmup to pre-trigger text selection code paths
    // This reduces JIT compilation delay on first selection in debug mode
    return SelectionWarmup(
      child: Scaffold(
        resizeToAvoidBottomInset: false, // Prevent repagination when keyboard opens (e.g. for dialogs)
        body: _ReaderGestureWrapper(
          // Completely separate: reader gestures only work when no selection is active
          isSelectionActive: _hasActiveSelection,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: pages.length,
                onPageChanged: _handlePageChanged,
                itemBuilder: (context, index) => pages[index],
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
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(ThemeData theme) {
    final displayProgress = (_progress * 100).clamp(0, 100).toStringAsFixed(1);
    return GestureDetector(
      onTap: () {
        setState(() {
          _showProgressBar = false;
        });
      },
      child: Container(
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
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text('$displayProgress %'),
          ],
        ),
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
            child: PageContentView(
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
      fontScale: _fontScale,
      onFontScaleChanged: _updateFontScale,
      hasChapters: _chapterEntries.isNotEmpty,
      onGoToChapter: _showChapterSelector,
      onGoToPercentage: _showGoToPercentageDialog,
      onShowSummaryFromBeginning: () => _openSummary(SummaryType.fromBeginning),
      onShowCharactersSummary: () => _openSummary(SummaryType.characters),
      onDeleteSummaries: () => unawaited(_confirmAndDeleteSummaries()),
      onReturnToLibrary: _returnToLibrary,
    ));
  }

  void _updateFontScale(double newScale) {
    if ((newScale - _fontScale).abs() < 0.01) {
      return; // No change
    }
    setState(() {
      _fontScale = newScale;
    });
    unawaited(_settingsService.saveReaderFontScale(_fontScale));
    _scheduleRepagination(retainCurrentPage: true);
  }

  Future<void> _confirmAndDeleteSummaries() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.summariesDeleteConfirmTitle),
        content: Text(l10n.summariesDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.summariesDeleteConfirmButton),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    if (!await _ensureSummaryServiceReady()) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);

    try {
      await _summaryService!.deleteBookSummaries(widget.book.id);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.summaryDeleted)),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.resetSummariesError)),
      );
    }
  }

  Future<void> _returnToLibrary() {
    return returnToLibrary(
      context,
      openLibrary: () => Navigator.of(context).pushReplacementNamed(libraryRoute),
    );
  }

  void _showChapterSelector() {
    final navigator = Navigator.of(context);
    _chapterDialogNavigator = navigator;
    
    showModalBottomSheet<void>(
      context: context,
      builder: (dialogContext) {
        return _ChapterSelectorDialog(
          chapters: _chapterEntries,
          getNavigationState: () => _isNavigating,
          getNavigatingToChapterIndex: () => _navigatingToChapterIndex,
          onChapterSelected: (chapterIndex) {
            // Set navigation state immediately (synchronously) for instant feedback
            setState(() {
              _isNavigating = true;
              _navigatingToChapterIndex = chapterIndex;
            });
            // Trigger immediate rebuild to show highlighting and start pulsating
            _chapterDialogRebuildCallback?.call();
            _goToChapter(chapterIndex);
          },
          onRebuildRequested: (callback) {
            _chapterDialogRebuildCallback = callback;
          },
        );
      },
    ).then((_) {
      // Clear references when dialog is dismissed (e.g., user swipes down)
      _chapterDialogNavigator = null;
      _chapterDialogRebuildCallback = null;
      _navigatingToChapterIndex = null;
    });
  }

  void _goToChapter(int chapterIndex) {
    if (_engine == null) {
      // Navigation cannot proceed, clear state and close dialog
      _clearNavigatingState();
      _closeChapterDialog();
      return;
    }

    // Find the first page of this chapter
    final pageIndex = _engine!.findPageForChapter(chapterIndex);
    if (pageIndex == null) {
      // Chapter page not found, clear state and close dialog
      _clearNavigatingState();
      _closeChapterDialog();
      return;
    }

    // Get that page and navigate to it
    final page = _engine!.getPage(pageIndex);
    if (page != null) {
      _scheduleRepagination(initialCharIndex: page.startCharIndex);
    } else {
      // Page not available, clear state and close dialog
      _clearNavigatingState();
      _closeChapterDialog();
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
        _lastVisibleCharacterIndex = currentPage.endCharIndex;
        // Don't log here, this is called frequently during background pagination
      } else {
        _lastVisibleCharacterIndex = null;
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

    final visibleIndex =
        _lastVisibleCharacterIndex ?? currentPage.endCharIndex;

    final progress = ReadingProgress(
      bookId: widget.book.id,
      currentCharacterIndex: currentPage.startCharIndex,
      lastVisibleCharacterIndex: visibleIndex,
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
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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

    // Extract CSS stylesheets
    final cssResolver = CssResolver();
    final cssFiles = epub.Content?.Css;
    if (cssFiles != null) {
      for (final entry in cssFiles.entries) {
        final cssContent = entry.value.Content;
        if (cssContent != null) {
          final cssString = cssContent.toString();
          if (cssString.isNotEmpty) {
            cssResolver.addStylesheet(entry.key, cssString);
          }
        }
      }
    }
    cssResolver.parseAll();

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
        cssResolver: cssResolver,
      );
      if (result.isNotEmpty) {
        chapters.add(_ChapterEntry(index: i, title: title));
        blocks.addAll(result);
      }
    }

    if (blocks.isEmpty) {
      final fallbackText = 'Aucun contenu lisible dans ce livre.';
      blocks.add(
        TextDocumentBlock(
          chapterIndex: 0,
          spacingBefore: 0,
          spacingAfter: _paragraphSpacing,
          text: fallbackText,
          nodes: [
            InlineTextNode(
              start: 0,
              end: fallbackText.length,
              style: const InlineTextStyle(fontStyle: FontStyle.italic),
            ),
          ],
          baseStyle: const InlineTextStyle(fontScale: 1.0),
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
    required CssResolver cssResolver,
  }) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) {
      return const [];
    }

    // Extract inline styles from <style> tags
    final styleTags = document.querySelectorAll('style');
    for (final styleTag in styleTags) {
      final cssContent = styleTag.text;
      if (cssContent.isNotEmpty) {
        cssResolver.addStylesheet('inline-${styleTag.hashCode}', cssContent);
      }
    }
    cssResolver.parseAll();

    final blocks = <DocumentBlock>[];
    bool isFirstBlock = true;
    _InlineCollector? activeCollector;
    Uint8List? imageResolver(String src) => _resolveImageBytes(src, images);

    bool isResultEmpty(_InlineContentResult result) {
      final cleaned = result.text.replaceAll('\uFFFC', '').trim();
      final hasPlaceholders =
          result.nodes.any((node) => node is InlinePlaceholderNode);
      return cleaned.isEmpty && !hasPlaceholders;
    }

    void addBlock(
      _InlineContentResult? result, {
      TextAlign textAlign = TextAlign.left,
      double? spacingBefore,
      double? spacingAfter,
      bool appendToCollector = false,
    }) {
      if (result == null || isResultEmpty(result)) {
        return;
      }
      
      // If we have an active collector and we're supposed to append, do that
      if (appendToCollector && activeCollector != null) {
        // Add paragraph break (double newline) before new content
        activeCollector!.appendLiteral('\n\n');
        // Append the result content
        activeCollector!.appendResult(result);
        return;
      }
      
      // Otherwise, create a new block
      final before = spacingBefore ?? (isFirstBlock ? 0 : 0.0); // No spacing between blocks
      final after = spacingAfter ?? 0.0; // No spacing after
      blocks.add(
        TextDocumentBlock(
          chapterIndex: chapterIndex,
          spacingBefore: before,
          spacingAfter: after,
          text: result.text,
          nodes: result.nodes,
          baseStyle: InlineTextStyle.empty,
          textAlign: textAlign,
        ),
      );
      isFirstBlock = false;
    }

    void flushActiveCollector() {
      if (activeCollector == null) return;
      final result = activeCollector!.build();
      activeCollector = null; // Clear before calling addBlock
      if (result != null && !isResultEmpty(result)) {
        blocks.add(
          TextDocumentBlock(
            chapterIndex: chapterIndex,
            spacingBefore: isFirstBlock ? 0 : 0.0,
            spacingAfter: 0.0,
            text: result.text,
            nodes: result.nodes,
            baseStyle: InlineTextStyle.empty,
            textAlign: TextAlign.left,
          ),
        );
        isFirstBlock = false;
      }
    }

    _InlineContentResult? buildBlockFromElement(
      dom.Element element,
    ) {
      final elementStyle = cssResolver.resolveStyles(element);
      final collector = _InlineCollector(
        resolveImage: imageResolver,
        baseStyle: elementStyle,
        cssResolver: cssResolver,
      );
      for (final child in element.nodes) {
        collector.collect(child);
      }
      return collector.build();
    }

    void processNode(dom.Node node) {
      if (node is dom.Element && _isLayoutArtifact(node)) {
        return;
      }

      if (node is dom.Element) {
        final name = node.localName?.toLowerCase();
        switch (name) {
          case 'style':
          case 'script':
            return;
          case 'p':
          case 'blockquote':
          case 'pre':
            // Append paragraph to active collector (don't create separate block)
            activeCollector ??= _InlineCollector(
              resolveImage: imageResolver,
              baseStyle: InlineTextStyle.empty,
              cssResolver: cssResolver,
            );
            // Add paragraph break if collector already has content
            if (activeCollector!.hasContent) {
              activeCollector!.appendLiteral('\n');
            }
            // Process paragraph content directly into collector
            for (final child in node.nodes) {
              activeCollector!.collect(child);
            }
            return;
          case 'h1':
          case 'h2':
          case 'h3':
          case 'h4':
          case 'h5':
          case 'h6':
            // Headings should flush and create new blocks
            flushActiveCollector();
            final hAlign = cssResolver.resolveTextAlign(node) ?? TextAlign.center;
            addBlock(
              buildBlockFromElement(node),
              textAlign: hAlign,
              spacingBefore: isFirstBlock ? 0 : _headingSpacing / 2,
              spacingAfter: _headingSpacing,
            );
            return;
          case 'ul':
          case 'ol':
            // Lists should append to active collector
            activeCollector ??= _InlineCollector(
              resolveImage: imageResolver,
              baseStyle: InlineTextStyle.empty,
              cssResolver: cssResolver,
            );
            if (activeCollector!.hasContent) {
              activeCollector!.appendLiteral('\n');
            }
            final ordered = name == 'ol';
            int counter = 1;
            for (final child in node.children.where((e) => e.localName == 'li')) {
              final childStyle = cssResolver.resolveStyles(child);
              final mergedStyle = activeCollector!._currentStyle.merge(childStyle);
              activeCollector!.pushStyle(mergedStyle, () {
                final bullet = ordered ? '$counter. ' : '• ';
                activeCollector!.appendLiteral(bullet);
                for (final grandChild in child.nodes) {
                  activeCollector!.collect(grandChild);
                }
              });
              activeCollector!.appendLiteral('\n');
              counter++;
            }
            return;
          case 'img':
            final src = node.attributes['src'];
            if (src != null) {
              final bytes = imageResolver(src);
              if (bytes != null) {
                final imageInfo = cssResolver.resolveImageStyle(node);
                if (imageInfo?.isBlock == true) {
                  // Block-level image - flush and create ImageDocumentBlock
                  flushActiveCollector();
                  blocks.add(
                    ImageDocumentBlock(
                      chapterIndex: chapterIndex,
                      spacingBefore: isFirstBlock ? 0 : 0.0, // No spacing
                      spacingAfter: 0.0, // No spacing
                      bytes: bytes,
                      intrinsicWidth: imageInfo?.width,
                      intrinsicHeight: imageInfo?.height,
                    ),
                  );
                  isFirstBlock = false;
                } else {
                  // Inline image - add to collector (don't flush)
                  activeCollector ??= _InlineCollector(
                    resolveImage: imageResolver,
                    baseStyle: InlineTextStyle.empty,
                    cssResolver: cssResolver,
                  );
                  activeCollector!.collect(node);
                }
              }
            }
            return;
          case 'div':
          case 'section':
          case 'article':
          case 'body':
            for (final child in node.nodes) {
              processNode(child);
            }
            return;
          // Inline formatting elements should never flush the collector
          // They should always be added to the active collector to keep text together
          case 'i':
          case 'em':
          case 'strong':
          case 'b':
          case 'span':
          case 'a':
          case 'code':
          case 'small':
          case 'sub':
          case 'sup':
          case 'u':
            // These are inline elements - add to collector without flushing
            activeCollector ??= _InlineCollector(
              resolveImage: imageResolver,
              baseStyle: InlineTextStyle.empty,
              cssResolver: cssResolver,
            );
            activeCollector!.collect(node);
            return;
          default:
            // Unknown element: treat contents as inline
            activeCollector ??= _InlineCollector(
              resolveImage: imageResolver,
              baseStyle: InlineTextStyle.empty,
              cssResolver: cssResolver,
            );
            activeCollector!.collect(node);
            return;
        }
      }

      if (node is dom.Text) {
        activeCollector ??= _InlineCollector(
          resolveImage: imageResolver,
          baseStyle: InlineTextStyle.empty,
          cssResolver: cssResolver,
        );
        activeCollector!.collect(node);
      }
    }

    for (final node in body.nodes) {
      processNode(node);
    }

    flushActiveCollector();

    return blocks;
  }

  bool _isLayoutArtifact(dom.Element element) {
    final classAttr = element.className.toLowerCase();
    if (classAttr.contains('pagebreak') || classAttr.contains('pagenum')) {
      return true;
    }

    final style = element.attributes['style']?.toLowerCase() ?? '';
    if (style.contains('page-break') || style.contains('break-before') || style.contains('break-after')) {
      return true;
    }
    if (style.contains('position:absolute') || style.contains('position: fixed')) {
      return true;
    }
    if (style.contains(RegExp(r'(width|height)\s*:\s*\d+px'))) {
      return true;
    }
    if (style.contains(RegExp(r'\b(top|left|right|bottom)\s*:'))) {
      return true;
    }

    return false;
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

class _InlineContentResult {
  const _InlineContentResult({
    required this.text,
    required this.nodes,
  });

  final String text;
  final List<InlineNode> nodes;

  bool get isEmpty => text.isEmpty && nodes.isEmpty;
}

typedef _ImageResolver = Uint8List? Function(String src);

class _InlineCollector {
  _InlineCollector({
    required _ImageResolver resolveImage,
    required InlineTextStyle baseStyle,
    required CssResolver cssResolver,
  })  : _resolveImage = resolveImage,
        _styleStack = [baseStyle],
        _cssResolver = cssResolver;

  final _InlineContentBuilder _builder = _InlineContentBuilder();
  final List<InlineTextStyle> _styleStack;
  final _ImageResolver _resolveImage;
  final CssResolver _cssResolver;
  bool _needsSpaceBeforeText = false;

  InlineTextStyle get _currentStyle => _styleStack.last;

  void collect(dom.Node node) {
    if (node is dom.Text) {
      _appendText(node.text);
      return;
    }
    if (node is! dom.Element) {
      for (final child in node.nodes) {
        collect(child);
      }
      return;
    }

    final name = node.localName?.toLowerCase();
    switch (name) {
      case 'br':
        _builder.appendText('\n', _currentStyle);
        _needsSpaceBeforeText = false;
        break;
      case 'strong':
      case 'b':
        final elementStyle = _cssResolver.resolveStyles(node);
        final mergedStyle = _currentStyle.merge(elementStyle).merge(
          const InlineTextStyle(fontWeight: FontWeight.bold),
        );
        pushStyle(mergedStyle, () {
          for (final child in node.nodes) {
            collect(child);
          }
        });
        break;
      case 'em':
      case 'i':
        final elementStyle = _cssResolver.resolveStyles(node);
        final mergedStyle = _currentStyle.merge(elementStyle).merge(
          const InlineTextStyle(fontStyle: FontStyle.italic),
        );
        pushStyle(mergedStyle, () {
          for (final child in node.nodes) {
            collect(child);
          }
        });
        break;
      case 'img':
        final src = node.attributes['src'];
        if (src != null) {
          final bytes = _resolveImage(src);
          if (bytes != null) {
            final imageInfo = _cssResolver.resolveImageStyle(node);
            // Images inside paragraphs/other inline contexts are always inline
            // (block-level CSS only applies to top-level images)
            final image = InlineImageContent(
              bytes: bytes,
              intrinsicWidth: imageInfo?.width,
              intrinsicHeight: imageInfo?.height,
            );
            _builder.appendPlaceholder(image);
            _needsSpaceBeforeText = false;
          }
        }
        break;
      default:
        // Apply CSS styles for other elements
        final elementStyle = _cssResolver.resolveStyles(node);
        if (!elementStyle.isPlain) {
          pushStyle(_currentStyle.merge(elementStyle), () {
            for (final child in node.nodes) {
              collect(child);
            }
          });
        } else {
          for (final child in node.nodes) {
            collect(child);
          }
        }
    }
  }

  _InlineContentResult? build() => _builder.build();

  bool get hasContent => _builder.hasContent;

  void appendLiteral(String value) {
    if (value.isEmpty) return;
    _builder.appendText(value, _currentStyle);
    _needsSpaceBeforeText = false;
  }
  
  void appendResult(_InlineContentResult result) {
    // Append all nodes from another result to this collector
    for (final node in result.nodes) {
      if (node is InlineTextNode) {
        final text = result.text.substring(node.start, node.end);
        _builder.appendText(text, node.style);
      } else if (node is InlinePlaceholderNode) {
        _builder.appendPlaceholder(node.image);
      }
    }
  }

  void _appendText(String value) {
    final cleaned = normalizeWhitespace(value);
    if (cleaned.isEmpty) {
      return;
    }
    var textToWrite = cleaned;
    if (_needsSpaceBeforeText &&
        _builder.hasContent &&
        !_startsWithWhitespace(cleaned)) {
      textToWrite = ' $textToWrite';
    }
    _builder.appendText(textToWrite, _currentStyle);
    _needsSpaceBeforeText = !_endsWithWhitespace(textToWrite);
  }

  void pushStyle(InlineTextStyle delta, VoidCallback body) {
    final merged = _currentStyle.merge(delta);
    _styleStack.add(merged);
    try {
      body();
    } finally {
      _styleStack.removeLast();
    }
  }

  bool _startsWithWhitespace(String value) {
    if (value.isEmpty) return false;
    final code = value.codeUnitAt(0);
    return code <= 32;
  }

  bool _endsWithWhitespace(String value) {
    if (value.isEmpty) return false;
    final code = value.codeUnitAt(value.length - 1);
    return code <= 32;
  }
}

class _InlineContentBuilder {
  final StringBuffer _buffer = StringBuffer();
  final List<InlineNode> _nodes = [];

  bool get hasContent => _buffer.isNotEmpty;

  void appendText(String text, InlineTextStyle style) {
    if (text.isEmpty) return;
    final start = _buffer.length;
    _buffer.write(text);
    final end = _buffer.length;
    if (_nodes.isNotEmpty &&
        _nodes.last is InlineTextNode &&
        (_nodes.last as InlineTextNode).style == style &&
        _nodes.last.end == start) {
      final last = _nodes.removeLast() as InlineTextNode;
      _nodes.add(
        InlineTextNode(
          start: last.start,
          end: end,
          style: last.style,
        ),
      );
    } else {
      _nodes.add(
        InlineTextNode(
          start: start,
          end: end,
          style: style,
        ),
      );
    }
  }

  void appendPlaceholder(InlineImageContent image) {
    final position = _buffer.length;
    _buffer.write('\uFFFC');
    _nodes.add(InlinePlaceholderNode(position: position, image: image));
  }

  _InlineContentResult? build() {
    if (_buffer.isEmpty) {
      _nodes.clear();
      return null;
    }
    final result = _InlineContentResult(
      text: _buffer.toString(),
      nodes: List<InlineNode>.from(_nodes),
    );
    _buffer.clear();
    _nodes.clear();
    return result;
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
    required this.viewportBottomInset,
  });

  final double maxWidth;
  final double maxHeight;
  final TextStyle baseTextStyle;
  final TextHeightBehavior textHeightBehavior;
  final TextScaler textScaler;
  final double viewportBottomInset;
}

@visibleForTesting
bool shouldKeepSelectionOnPointerUp({
  required bool hasSelection,
  required bool isSelectionOwnerPointer,
  required bool slopExceeded,
  required Duration? pressDuration,
  required DateTime? lastSelectionChangeTimestamp,
  required DateTime now,
  Duration deferWindow = const Duration(milliseconds: 250),
  Duration longPressThreshold = const Duration(milliseconds: 450),
}) {
  if (!hasSelection) return false;
  if (isSelectionOwnerPointer) return true;
  if (slopExceeded) return true;
  if (pressDuration != null && pressDuration >= longPressThreshold) return true;
  final withinDeferWindow = lastSelectionChangeTimestamp != null &&
      now.difference(lastSelectionChangeTimestamp) < deferWindow;
  if (withinDeferWindow) return true;
  return false;
}

/// Dialog widget that shows chapter list with pulsating effect on selected chapter during navigation.
class _ChapterSelectorDialog extends StatefulWidget {
  const _ChapterSelectorDialog({
    required this.chapters,
    required this.getNavigationState,
    required this.getNavigatingToChapterIndex,
    required this.onChapterSelected,
    required this.onRebuildRequested,
  });

  final List<_ChapterEntry> chapters;
  final bool Function() getNavigationState;
  final int? Function() getNavigatingToChapterIndex;
  final void Function(int) onChapterSelected;
  final void Function(VoidCallback) onRebuildRequested;

  @override
  State<_ChapterSelectorDialog> createState() => _ChapterSelectorDialogState();
}

class _ChapterSelectorDialogState extends State<_ChapterSelectorDialog> {
  @override
  void initState() {
    super.initState();
    // Register rebuild callback with parent
    widget.onRebuildRequested(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isNavigating = widget.getNavigationState();
    final navigatingToIndex = widget.getNavigatingToChapterIndex();
    
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
              itemCount: widget.chapters.length,
              itemBuilder: (context, index) {
                final chapter = widget.chapters[index];
                final isNavigatingTo = isNavigating && navigatingToIndex == chapter.index;
                return _PulsatingChapterTile(
                  chapterTitle: chapter.title,
                  isNavigating: isNavigatingTo,
                  onTap: () => widget.onChapterSelected(chapter.index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Chapter tile with pulsating effect when navigation is in progress.
class _PulsatingChapterTile extends StatefulWidget {
  const _PulsatingChapterTile({
    required this.chapterTitle,
    required this.isNavigating,
    required this.onTap,
  });

  final String chapterTitle;
  final bool isNavigating;
  final VoidCallback onTap;

  @override
  State<_PulsatingChapterTile> createState() => _PulsatingChapterTileState();
}

class _PulsatingChapterTileState extends State<_PulsatingChapterTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _animation = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
    
    if (widget.isNavigating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_PulsatingChapterTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isNavigating && !oldWidget.isNavigating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isNavigating && oldWidget.isNavigating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ListTile(
          title: Text(widget.chapterTitle),
          onTap: widget.onTap,
          selected: widget.isNavigating,
          selectedTileColor: widget.isNavigating
              ? theme.colorScheme.primary.withOpacity(_animation.value * 0.2)
              : null,
          tileColor: widget.isNavigating
              ? theme.colorScheme.primary.withOpacity(_animation.value * 0.2)
              : null,
        );
      },
    );
  }
}

/// Widget that completely separates reader navigation gestures from text selection.
/// 
/// When [isSelectionActive] is true, all reader gestures are completely disabled.
/// When [isSelectionActive] is false, reader gestures work normally.
/// 
/// This ensures clean separation: either we're in READER MODE or SELECTION MODE,
/// never both at the same time.
class _ReaderGestureWrapper extends StatelessWidget {
  const _ReaderGestureWrapper({
    required this.isSelectionActive,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
    required this.child,
  });

  final bool isSelectionActive;
  final void Function(PointerDownEvent) onPointerDown;
  final void Function(PointerMoveEvent) onPointerMove;
  final void Function(PointerUpEvent) onPointerUp;
  final void Function(PointerCancelEvent) onPointerCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Always use Listener but defer to child (SelectableText) for selection gestures
    // This allows both reader navigation and text selection to coexist
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: onPointerDown,
      onPointerMove: onPointerMove,
      onPointerUp: onPointerUp,
      onPointerCancel: onPointerCancel,
      child: child,
    );
  }
}
