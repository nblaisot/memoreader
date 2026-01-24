import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:epubx/epubx.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDownEvent, PointerUpEvent, PointerCancelEvent;
import 'package:flutter/services.dart';
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
import '../services/saved_translation_database_service.dart';
import '../services/rag_query_service.dart';
import '../services/rag_indexing_service.dart';
import '../services/latest_events_service.dart';
import '../models/rag_index_progress.dart';
import '../models/saved_translation.dart';
import '../utils/html_text_extractor.dart';
import '../utils/css_resolver.dart';
import '../utils/app_route_observer.dart';
import 'reader/document_model.dart';
import 'reader/line_metrics_pagination_engine.dart';
import 'reader/page_content_view.dart';
import 'reader/pagination_cache.dart';
import 'reader/tap_zones.dart';
import 'reader/reader_menu.dart';
import 'reader/navigation_helper.dart';
import 'reader/selection_warmup.dart';
import 'reader/immediate_text_selection_controls.dart';
import 'reader/webview_reader.dart';
import 'routes.dart';
import 'settings_screen.dart';
import 'summary_screen.dart';
import 'saved_words_screen.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book});

  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver, RouteAware {
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
  String? _webViewHtml;
  String? _webViewFullText;
  List<_ChapterOffset> _chapterCharOffsets = [];
  final WebViewReaderController _webViewController = WebViewReaderController();
  int? _currentChapterIndex;
  int? _pendingWebViewCharIndex;
  double? _pendingRestorePercentage; // For non-WebView readers
  bool _hasRestoredProgress = false; // Track if we've already restored progress
  bool _isWaitingForWebViewInit = false; // Track if we're waiting for WebView to fully initialize
  bool _stylesAppliedForRestore = false; // True after we've sent our styles; we restore only after this so layout is stable
  String? _lastWebViewStyleKey;
  String? _lastWebViewLayoutKey;
  String? _lastWebViewActionLabel;
  bool? _lastWebViewActionEnabled;

  LineMetricsPaginationEngine? _engine;
  final PaginationCacheManager _cacheManager = const PaginationCacheManager();
  final SummaryDatabaseService _summaryDatabase = SummaryDatabaseService();
  final SavedTranslationDatabaseService _translationDatabase = 
      SavedTranslationDatabaseService();
  final RagQueryService _ragQueryService = RagQueryService();
  final RagIndexingService _ragIndexingService = RagIndexingService();
  StreamSubscription<RagIndexProgress>? _ragIndexingSubscription;
  RagIndexProgress? _ragIndexProgress;

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
  _PageMetrics? _currentPageMetrics; // Store current layout metrics for progress saving
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
  WebViewSelection? _webViewSelection;
  /// Single GlobalKey on the Positioned.fill that wraps WebViewReader.
  /// Used for selection toolbar coordinate conversion (WebView and overlay share same bounds).
  final GlobalKey _webViewKey = GlobalKey();
  bool _routeObserverSubscribed = false;
  // Minimal pointer tracking for quick tap detection only
  int? _activePointerId;
  Offset? _activePointerDownPosition;
  DateTime? _activePointerDownTime;
  static const Duration _quickTapThreshold = Duration(milliseconds: 300);
  // Pre-instantiated selection controls to avoid lazy loading and JIT delays
  ImmediateTextSelectionControls? _sharedSelectionControls;
  // Track if auto-show latest events has been triggered for this book session
  bool _hasTriggeredAutoShowLatestEvents = false;

  bool get _useWebViewReader {
    if (kIsWeb) {
      return false;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return false;
    }
  }

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
    _startListeningToRagIndexing();
    unawaited(_appStateService.setLastOpenedBook(widget.book.id));
  }

  void _startListeningToRagIndexing() {
    // Listen to RAG indexing progress
    _ragIndexingSubscription = _ragIndexingService.startIndexing(widget.book.id).listen(
      (progress) {
        if (mounted) {
          setState(() {
            _ragIndexProgress = progress;
          });
        }
      },
      onError: (error) {
        debugPrint('[RAG] Error listening to indexing progress: $error');
      },
      onDone: () {
        debugPrint('[RAG] Indexing progress stream completed');
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeObserverSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute<dynamic>) {
        appRouteObserver.subscribe(this, route);
        _routeObserverSubscribed = true;
      }
    }
    final locale = Localizations.localeOf(context);
    if (_lastLocale != locale) {
      _lastLocale = locale;
      _loadSelectionActionConfig();
    }
    // Initialize selection controls here since we need context for Localizations
    if (_sharedSelectionControls == null) {
      _initializeSelectionControls();
    }
  }
  
  void _initializeSelectionControls() {
    // Force instantiation of selection controls to load all code paths
    // This ensures JIT compilation happens upfront, not on first selection
    final l10n = AppLocalizations.of(context);
    final defaultActionLabel = l10n?.textSelectionDefaultLabel ?? 'Traduire';
    final actionLabel = (_selectionActionLabel ?? defaultActionLabel).trim().isEmpty
        ? defaultActionLabel
        : (_selectionActionLabel ?? defaultActionLabel);
    
    _sharedSelectionControls = ImmediateTextSelectionControls(
      onSelectionAction: _handleSelectionAction,
      actionLabel: actionLabel,
      clearSelection: () {}, // Will be set per page via callbacks
      isProcessingAction: false,
      getSelectedText: () => '', // Will be set per page via callbacks
    );
    
    debugPrint('[ReaderScreen] Selection controls pre-instantiated');
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
    _ragIndexingSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _engine?.removeListener(_handleEngineUpdate);
    _pageController.dispose();
    _progressDebounce?.cancel();
    if (_routeObserverSubscribed) {
      appRouteObserver.unsubscribe(this);
    }
    
    // Disable wake lock when leaving reader screen
    WakelockPlus.disable();
    
    // Always update reading stop when leaving reader (all interruptions are tracked)
    // Only if the book was actually loaded
    if (_epubBook != null) {
      _updateLastReadingStopOnExit();
    }
    
    super.dispose();
  }

  /// Safely navigate back to the library, cleaning up resources
  void _goBackToLibrary() {
    debugPrint('[ReaderScreen] _goBackToLibrary called');
    debugPrint('[ReaderScreen] mounted: $mounted');
    debugPrint('[ReaderScreen] canPop: ${Navigator.of(context).canPop()}');
    
    // Disable wake lock before leaving
    WakelockPlus.disable();
    
    // Clear the last opened book since we're going back due to an error
    unawaited(_appStateService.clearLastOpenedBook());
    
    // Navigate back - try different approaches
    if (mounted) {
      final navigator = Navigator.of(context, rootNavigator: true);
      debugPrint('[ReaderScreen] Navigator.canPop(): ${navigator.canPop()}');

      if (navigator.canPop()) {
        debugPrint('[ReaderScreen] Calling Navigator.pop()');
        navigator.pop();
      } else {
        debugPrint('[ReaderScreen] Cannot pop, pushing library route');
        navigator.pushNamedAndRemoveUntil(libraryRoute, (_) => false);
      }
    } else {
      debugPrint('[ReaderScreen] Widget is not mounted, cannot navigate');
    }
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
      if (_useWebViewReader) {
        unawaited(_saveWebViewProgress());
        unawaited(_updateLastReadingStopOnExit());
      } else {
        final page = _engine?.getPage(_currentPageIndex);
        if (page != null) {
          unawaited(_saveProgress(page));
          // Update reading stop when app goes to background
          unawaited(_updateLastReadingStopOnExit());
        }
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

  @override
  void didPopNext() {
    super.didPopNext();
    unawaited(_refreshReaderLayoutFromSettings());
  }

  Future<void> _refreshReaderLayoutFromSettings() async {
    await _loadVerticalPadding();
    if (!mounted) return;
    _scheduleRepagination(retainCurrentPage: true);
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
      final webViewDocument =
          _useWebViewReader ? _buildWebViewDocument(epub) : null;

      setState(() {
        _epubBook = epub;
        _docBlocks = extraction.blocks;
        _chapterEntries = extraction.chapters;
        _webViewHtml = webViewDocument?.html;
        _webViewFullText = webViewDocument?.fullText;
        _chapterCharOffsets = webViewDocument?.chapterCharOffsets ?? [];
        _totalCharacterCount =
            webViewDocument?.totalCharacters ?? extraction.totalCharacters;
        _currentPageIndex = 0;
        _totalPages = 0;
        _progress = 0.0;
        _savedProgress = progress;
        _lastVisibleCharacterIndex =
            progress?.lastVisibleCharacterIndex ?? progress?.currentCharacterIndex;
        _currentChapterIndex = null;
        _lastWebViewStyleKey = null;
        _lastWebViewLayoutKey = null;
        _lastWebViewActionLabel = null;
        _lastWebViewActionEnabled = null;
        _stylesAppliedForRestore = false;
        _isLoading = false;
        _hasTriggeredAutoShowLatestEvents = false; // Reset for new book load
      });

      // Use character index for restoration (prefer start of page over end)
      final savedCharIndex = progress?.currentCharacterIndex ??
                             progress?.lastVisibleCharacterIndex;
      
      if (kDebugMode) {
        debugPrint('[ReaderScreen] Restoring progress: savedCharIndex=$savedCharIndex');
      }
      
      // Wait for WebView initialization before restoration
      if (savedCharIndex != null && savedCharIndex > 0) {
        _hasRestoredProgress = false; // Reset flag for new book load
        _isWaitingForWebViewInit = _useWebViewReader;
        if (kDebugMode) {
          debugPrint('[ReaderScreen] Will restore to character index $savedCharIndex');
        }
      } else {
        _hasRestoredProgress = false;
        _isWaitingForWebViewInit = _useWebViewReader;
        if (kDebugMode) {
          debugPrint('[ReaderScreen] No saved position, starting from beginning');
        }
      }
      
      // Don't set _isNavigating here - wait for first page update, then restore
      if (!_useWebViewReader) {
        // For non-WebView, we need to wait for pagination to complete
        // Store the percentage to restore after pagination
        _pendingRestorePercentage = progress?.progress;
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _isWaitingForWebViewInit = false; // Clear waiting flag on error
        _errorMessage = e.toString();
      });
    }
  }

  void _scheduleRepagination({int? initialCharIndex, bool retainCurrentPage = false, Size? actualSize}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_useWebViewReader) {
        if (!mounted) return;
        final targetCharIndex = initialCharIndex ?? _currentCharacterIndex;
        _pendingWebViewCharIndex = math.max(0, targetCharIndex);
        setState(() {
          _isNavigating = true;
        });
        unawaited(_webViewController.updateLayout());
        return;
      }
      if (!mounted || _docBlocks.isEmpty) return;
      int? targetCharIndex;
      if (retainCurrentPage) {
        final currentPage = _engine?.getPage(_currentPageIndex);
        // Prioritize lastVisibleCharacterIndex (where user was reading) over currentCharacterIndex
        targetCharIndex =
            currentPage?.startCharIndex ?? 
            _savedProgress?.lastVisibleCharacterIndex ?? 
            _savedProgress?.currentCharacterIndex;
      } else if (initialCharIndex != null) {
        targetCharIndex = initialCharIndex;
      }

      // Prioritize lastVisibleCharacterIndex (where user was reading) over currentCharacterIndex
      targetCharIndex ??= _savedProgress?.lastVisibleCharacterIndex ?? 
                          _savedProgress?.currentCharacterIndex ?? 
                          0;
      targetCharIndex = math.max(0, targetCharIndex);

      unawaited(_rebuildPagination(targetCharIndex, actualSize: actualSize));
    });
  }

  Future<void> _rebuildPagination(int startCharIndex, {Size? actualSize, bool fastMode = false}) async {
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
      
      // Store current metrics for progress saving
      _currentPageMetrics = metrics;
      
      // Check if layout matches saved progress (for cache reuse)
      // If layout doesn't match, use fast mode for progressive pagination
      if (!fastMode && _savedProgress != null) {
        fastMode = !_layoutsMatch(_savedProgress, metrics);
      }

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
        cacheManager: _cacheManager,
        viewportInsetBottom: metrics.viewportBottomInset,
      );

      if (!mounted) {
        _clearNavigatingState();
        return;
      }
      
      // Use smaller window radius for fast mode to display content immediately
      final windowRadius = fastMode ? 1 : 3;
      final targetPageIndex =
          await engine.ensurePageForCharacter(startCharIndex, windowRadius: windowRadius);
      engine.addListener(_handleEngineUpdate);
      
      // In fast mode, compute minimal window then continue in background
      // In normal mode, compute larger window before continuing
      if (fastMode) {
        // Compute minimal window for immediate display
        await engine.ensureWindow(targetPageIndex, radius: 1);
        // Start background pagination immediately to continue computing pages
        unawaited(engine.startBackgroundPagination());
      } else {
        // Normal mode: compute larger window, then continue
        await engine.ensureWindow(targetPageIndex, radius: windowRadius);
        unawaited(engine.startBackgroundPagination());
      }

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
            
            // Restore saved page index or percentage
            // CRITICAL: Check if layout matches (screen size, font, etc.) before using page index
            final savedPageIndex = _savedProgress?.currentPageIndex;
            final pendingRestore = _pendingRestorePercentage;
            
            // Check if layout matches - if screen size changed, page index won't be accurate
            bool layoutMatches = false;
            if (_savedProgress != null && metrics != null) {
              layoutMatches = _layoutsMatch(_savedProgress, metrics);
            }
            
            if (savedPageIndex != null && savedPageIndex >= 0 && savedPageIndex < engine.estimatedTotalPages && layoutMatches) {
              // BEST: Use saved page index directly - layout matches, so page index is accurate!
              _pendingRestorePercentage = null;
              final targetPage = engine.getPage(savedPageIndex);
              if (targetPage != null && targetPage.startCharIndex != initialPage?.startCharIndex) {
                debugPrint('[ReaderScreen] Layout matches - restoring to saved page index: $savedPageIndex');
                _scheduleRepagination(initialCharIndex: targetPage.startCharIndex);
              } else {
                debugPrint('[ReaderScreen] Already at correct page index: $savedPageIndex');
              }
            } else if (pendingRestore != null && updatedTotalChars > 0) {
              // FALLBACK: Use percentage if layout changed or page index not available
              // Percentage works across different screen sizes (foldable phone support)
              _pendingRestorePercentage = null;
              
              if (savedPageIndex != null && !layoutMatches) {
                debugPrint('[ReaderScreen] Layout changed (screen size/font different) - using percentage instead of page index');
              }
              // FALLBACK: Use percentage if page index not available
              _pendingRestorePercentage = null;
              final savedPercentage = pendingRestore * 100.0; // Convert to 0-100 range
              final currentPercentage = initialPage != null
                  ? _calculateProgressForPage(initialPage, totalChars: updatedTotalChars) * 100.0
                  : 0.0;
              
              // Only navigate if we're significantly off (more than 0.5%)
              if ((savedPercentage - currentPercentage).abs() > 0.5) {
                debugPrint('[ReaderScreen] Restoring to saved progress: ${savedPercentage.toStringAsFixed(1)}% (current: ${currentPercentage.toStringAsFixed(1)}%)');
                // Use the same jumpToPercentage method that the menu uses
                _jumpToPercentage(savedPercentage);
              } else {
                debugPrint('[ReaderScreen] Already at correct position: ${currentPercentage.toStringAsFixed(1)}%');
              }
            }
            
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

  /// Compute layout key matching the pagination engine's layout key computation.
  /// This is used to match saved layouts with current layout for cache reuse.
  String _computeLayoutKey(_PageMetrics metrics) {
    final buffer = StringBuffer()
      ..write('v3|')
      ..write(metrics.baseTextStyle.fontFamily ?? 'default')
      ..write('|')
      ..write((metrics.baseTextStyle.fontSize ?? 16.0).toStringAsFixed(2))
      ..write('|')
      ..write((metrics.baseTextStyle.height ?? 1.0).toStringAsFixed(2))
      ..write('|')
      ..write(metrics.maxWidth.toStringAsFixed(1))
      ..write('|')
      ..write(metrics.maxHeight.toStringAsFixed(1))
      ..write('|')
      ..write(metrics.textHeightBehavior.applyHeightToFirstAscent ? '1' : '0')
      ..write(metrics.textHeightBehavior.applyHeightToLastDescent ? '1' : '0')
      ..write('|')
      ..write(metrics.textScaler.hashCode)
      ..write('|')
      ..write(metrics.viewportBottomInset.toStringAsFixed(1));
    return base64UrlEncode(buffer.toString().codeUnits);
  }

  /// Check if current layout matches saved layout from progress.
  /// Returns true if layouts are compatible (same layout key).
  bool _layoutsMatch(ReadingProgress? progress, _PageMetrics currentMetrics) {
    if (progress?.layoutKey == null) return false;
    final currentLayoutKey = _computeLayoutKey(currentMetrics);
    return progress!.layoutKey == currentLayoutKey;
  }

  /// Check if WebView is fully initialized and ready for restoration
  bool _isWebViewReadyForRestoration(WebViewPageUpdate update) {
    // WebView must report it's ready
    if (!_webViewController.isReady) return false;
    
    // Must have calculated total characters (not just 0)
    if (update.totalChars <= 0) return false;
    
    // Must have at least one page
    // (pageCount = 0 means still calculating, pageCount >= 1 is valid)
    if (update.pageCount <= 0) return false;
    
    // Character indices must be valid
    if (update.startCharIndex == null || update.endCharIndex == null) return false;
    
    return true;
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

  void _scheduleWebViewProgressSave() {
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _saveWebViewProgress();
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



  void _handlePointerDown(PointerDownEvent event) {
    // Only track if we don't already have an active pointer
    if (_activePointerId != null) {
      return;
    }
    _activePointerId = event.pointer;
    _activePointerDownPosition = event.position;
    _activePointerDownTime = DateTime.now();
  }

  void _handlePointerUp(PointerUpEvent event) {
    // Only handle if this is our tracked pointer
    if (event.pointer != _activePointerId) {
      return;
    }

    final downTime = _activePointerDownTime;
    final downPosition = _activePointerDownPosition;

    // Reset tracking immediately
    _resetPointerTracking();

    // If selection is now active, clear it on tap
    if (_hasActiveSelection) {
      _clearSelectionCallback?.call();
      return;
    }

    // Check if it was a quick tap (not a long press)
    if (downTime != null) {
      final duration = DateTime.now().difference(downTime);
      if (duration > _quickTapThreshold) {
        // Was a long press - ignore (SelectableText handled it)
        return;
      }
    }

    // It was a quick tap - determine tap zone and handle navigation
    if (downPosition != null) {
      _handleTapAtPosition(downPosition);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activePointerId) {
      _resetPointerTracking();
    }
  }

  void _resetPointerTracking() {
    _activePointerId = null;
    _activePointerDownPosition = null;
    _activePointerDownTime = null;
  }

  void _handleTapAtPosition(Offset position) {
    final screenSize = MediaQuery.of(context).size;
    final action = determineTapAction(position, screenSize);
    debugPrint('[ReaderScreen] Tap -> $action at $position');

    switch (action) {
      case ReaderTapAction.showMenu:
        unawaited(_openReadingMenu());
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
    // STATE TRANSITION: Switch between reader mode and selection mode
    if (hasSelection) {
      // Entering SELECTION MODE
      _clearSelectionCallback = clearSelection;
      _lastSelectionChangeTimestamp = DateTime.now();
      _resetPointerTracking(); // Clear any pointer tracking when selection activates
      debugPrint('[ReaderScreen] STATE: Entering SELECTION MODE');
    } else {
      // Entering READER MODE
      _clearSelectionCallback = null;
      _lastSelectionChangeTimestamp = null;
      _selectionOwnerPointer = null;
      _resetPointerTracking(); // Clear pointer tracking when selection deactivates
      debugPrint('[ReaderScreen] STATE: Entering READER MODE');
    }

    if (_hasActiveSelection != hasSelection) {
      setState(() {
        _hasActiveSelection = hasSelection;
      });
    }
  }

  void _handleWebViewSelectionChanged(
    WebViewSelection? selection,
    VoidCallback clearSelection,
  ) {
    final trimmedText = selection?.text.trim() ?? '';
    if (trimmedText.isEmpty) {
      if (_webViewSelection != null) {
        setState(() {
          _webViewSelection = null;
        });
      }
      _handleSelectionChanged(false, clearSelection);
      return;
    }

    final normalizedSelection = WebViewSelection(
      text: trimmedText,
      rect: selection!.rect,
    );
    setState(() {
      _webViewSelection = normalizedSelection;
    });
    _handleSelectionChanged(true, clearSelection);
  }

  void _clearSelectionState() {
    setState(() {
      _hasActiveSelection = false;
      _lastSelectionChangeTimestamp = null;
      _selectionOwnerPointer = null;
      _webViewSelection = null;
    });
    _clearSelectionCallback?.call();
    _clearSelectionCallback = null;
  }

  Future<void> _saveProgress(PageContent page) async {
    try {
      // Save the displayed progress percentage (what user sees at bottom)
      // This is more reliable than character indices
      final progressPercentage = _progress;
      
      // Capture current layout metrics if available
      String? layoutKey;
      double? maxWidth;
      double? maxHeight;
      double? fontSize;
      double? horizontalPadding;
      double? verticalPadding;
      
      if (_currentPageMetrics != null) {
        final metrics = _currentPageMetrics!;
        layoutKey = _computeLayoutKey(metrics);
        maxWidth = metrics.maxWidth;
        maxHeight = metrics.maxHeight;
        fontSize = metrics.baseTextStyle.fontSize;
        horizontalPadding = _horizontalPadding;
        verticalPadding = _verticalPadding;
      }
      
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentCharacterIndex: page.startCharIndex,
        lastVisibleCharacterIndex: page.endCharIndex,
        currentPageIndex: _currentPageIndex, // Save the actual page index
        progress: progressPercentage, // Save the displayed progress percentage
        lastRead: DateTime.now(),
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontSize: fontSize,
        horizontalPadding: horizontalPadding,
        verticalPadding: verticalPadding,
        layoutKey: layoutKey,
      );
      await _bookService.saveReadingProgress(progress);
      _savedProgress = progress;
      
      if (kDebugMode) {
        debugPrint('[ReaderScreen] Saved progress: ${(progressPercentage * 100).toStringAsFixed(1)}%');
      }
    } catch (_) {
      // Saving progress is best-effort; ignore failures.
    }
  }

  Future<void> _saveWebViewProgress() async {
    try {
      // Save the displayed progress percentage (what user sees at bottom)
      // This is more reliable than character indices
      final progressPercentage = _progress;
      
      // Capture current layout metrics if available
      String? layoutKey;
      double? maxWidth;
      double? maxHeight;
      double? fontSize;
      double? horizontalPadding;
      double? verticalPadding;

      if (_currentPageMetrics != null) {
        final metrics = _currentPageMetrics!;
        layoutKey = _computeLayoutKey(metrics);
        maxWidth = metrics.maxWidth;
        maxHeight = metrics.maxHeight;
        fontSize = metrics.baseTextStyle.fontSize;
        horizontalPadding = _horizontalPadding;
        verticalPadding = _verticalPadding;
      }

      if (kDebugMode) {
        debugPrint('[ReaderScreen] Saved WebView progress: ${(progressPercentage * 100).toStringAsFixed(1)}% (exact: ${progressPercentage})');
      }

      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentCharacterIndex: _currentCharacterIndex,
        lastVisibleCharacterIndex: _lastVisibleCharacterIndex,
        currentPageIndex: _currentPageIndex, // Save the actual page index - most reliable!
        progress: progressPercentage, // Save the displayed progress percentage
        lastRead: DateTime.now(),
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontSize: fontSize,
        horizontalPadding: horizontalPadding,
        verticalPadding: verticalPadding,
        layoutKey: layoutKey,
      );
      await _bookService.saveReadingProgress(progress);
      _savedProgress = progress;
    } catch (e) {
      debugPrint('[ReaderScreen] Failed to save WebView progress: $e');
      // Saving progress is best-effort; ignore failures.
    }
  }

  /// Update the last reading stop position when leaving the reader
  /// This is called when the user actually stops reading (not just saving progress)
  Future<void> _updateLastReadingStopOnExit() async {
    try {
      final startCharIndex = _useWebViewReader
          ? _currentCharacterIndex
          : _engine?.getPage(_currentPageIndex)?.startCharIndex;
      if (startCharIndex == null) return;
      final chunkIndex = _summaryService != null
          ? _summaryService!.estimateChunkIndexForCharacter(startCharIndex)
          : EnhancedSummaryService.computeChunkIndexForCharacterStatic(startCharIndex);
      
      unawaited(_summaryDatabase.updateLastReadingStop(
        widget.book.id,
        chunkIndex: chunkIndex,
        characterIndex: startCharIndex,
      ));
      if (_summaryService != null) {
        unawaited(_summaryService!.updateLastReadingStop(
          widget.book.id,
          chunkIndex: chunkIndex,
          characterIndex: startCharIndex,
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
    if (_useWebViewReader) {
      if (_totalPages > 0 && _currentPageIndex >= _totalPages - 1) {
        return false;
      }
      unawaited(_webViewController.goToNextPage());
      return true;
    }
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
    if (_useWebViewReader) {
      if (_currentPageIndex <= 0) {
        if (_showProgressBar) {
          setState(() {
            _showProgressBar = false;
          });
        }
        return false;
      }
      unawaited(_webViewController.goToPreviousPage());
      return true;
    }
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

  void _handleWebViewPageChanged(WebViewPageUpdate update) {
    final startChar = update.startCharIndex ?? 0;
    final endChar = update.endCharIndex ?? startChar;
    final totalChars = update.totalChars;
    final progress = totalChars > 0
        ? (math.min(totalChars, math.max(0, endChar + 1)) / totalChars)
        : 0.0;

    if (kDebugMode) {
      debugPrint('[WebView] PAGE_CHANGED: page=${update.pageIndex}/${update.pageCount}, chars=$startChar-$endChar/$totalChars, waiting=$_isWaitingForWebViewInit, restored=$_hasRestoredProgress, loading=$_isLoading');
    }

    // Update state first so _totalCharacterCount is available
    if (kDebugMode) {
      final previousEnd = _lastVisibleCharacterIndex;
      if (previousEnd != null) {
        final gap = startChar - previousEnd - 1;
        if (gap > 1) {
          debugPrint('[WebView] Page gap detected: +$gap chars (prevEnd=$previousEnd start=$startChar page=${update.pageIndex})');
        } else if (gap < -1) {
          debugPrint('[WebView] Page overlap detected: ${gap.abs()} chars (prevEnd=$previousEnd start=$startChar page=${update.pageIndex})');
        }
      }
    }

    setState(() {
      _currentPageIndex = update.pageIndex;
      _totalPages = update.pageCount;
      _totalCharacterCount = totalChars; // CRITICAL: Set this FIRST
      _currentCharacterIndex = startChar;
      _lastVisibleCharacterIndex = endChar;
      _progress = progress;
      _currentChapterIndex = _resolveChapterIndexForChar(startChar);
      _showProgressBar = false;
      
      // Clear navigation flag only when restoration is complete (or not applicable)
      // During restoration we keep overlay visible until we've reached the saved position
      if (_hasRestoredProgress) {
        _isNavigating = false;
      }
      
      _navigatingToChapterIndex = null;
    });

    // Handle pending character index navigation (for chapter navigation, or from restoration when WebView wasn't ready)
    final pendingCharIndex = _pendingWebViewCharIndex;
    if (pendingCharIndex != null && totalChars > 0 && _webViewController.isReady) {
      _pendingWebViewCharIndex = null;
      if (pendingCharIndex > 0) {
        // Clamp to valid range based on WebView's reported total
        final clamped = pendingCharIndex.clamp(0, totalChars - 1);
        final currentStartChar = startChar;
        // Only navigate if we're significantly off from current position
        if ((clamped - currentStartChar).abs() > 1) {
          debugPrint('[WebView] Navigating to char index: $clamped (current: $currentStartChar, total: $totalChars)');
          setState(() {
            _isNavigating = true;
          });
          unawaited(_webViewController.goToCharIndex(clamped));
          _scheduleWebViewProgressSave();
          _closeChapterDialog();
          return;
        }
      }
    }

    // PHASE 1: First update ("ready") – WebView has loaded. Do NOT restore yet.
    // We will apply our styles in PostFrameCallback; that triggers updateLayout and a second
    // page update. We restore only after that, so layout is stable (no re-pagination glitches).
    if (_isWaitingForWebViewInit) {
      if (!_isWebViewReadyForRestoration(update)) {
        debugPrint('[WebView] INIT: Not ready yet - totalChars=${update.totalChars}, pageCount=${update.pageCount}, ready=${_webViewController.isReady}');
        return;
      }
      debugPrint('[WebView] INIT: WebView ready (first update) - totalChars=${update.totalChars}, pageCount=${update.pageCount}. Waiting for styles then restore.');
      if (_currentPageMetrics != null) {
        _lastWebViewLayoutKey = _computeLayoutKey(_currentPageMetrics!);
      }
      setState(() {
        _isWaitingForWebViewInit = false;
        _isNavigating = true; // Keep overlay until we've restored on next update
      });
      return; // Skip Phase 2; next update will be after our updateStyles → updateLayout
    }

    // PHASE 2: Restore only after our styles are applied (_stylesAppliedForRestore).
    // Run restore logic only while we have not yet restored (_hasRestoredProgress false).
    // Once restored, skip this block on subsequent page flips – we must not navigate back
    // to saved position when the user flips forward (e.g. past a chapter boundary).
    if (!_stylesAppliedForRestore || !_webViewController.isReady || update.pageCount <= 0) {
      return;
    }

    if (!_hasRestoredProgress) {
      // Prefer currentCharacterIndex (start of page) over lastVisible (end).
      // Restoring to start avoids layout-induced jump: when we use end, the page
      // containing it can extend further after layout change, so displayed % jumps
      // forward (e.g. 38.6% -> 38.9%). Start is a more stable anchor.
      final savedCharIndex = _savedProgress?.currentCharacterIndex ??
                             _savedProgress?.lastVisibleCharacterIndex;

      if (savedCharIndex != null && savedCharIndex > 0) {
        if (savedCharIndex >= startChar && savedCharIndex <= endChar) {
          // Reached saved position (second update from updateLayout, or confirm after navigate).
          _hasRestoredProgress = true;
          debugPrint('[WebView] RESTORE: Reached saved position (savedChar=$savedCharIndex, page $startChar–$endChar)');
          setState(() {
            _isNavigating = false;
          });
        } else {
          // Not at position – navigate once. Next page update will confirm.
          debugPrint('[WebView] RESTORE: Navigating to character index $savedCharIndex (current page $startChar–$endChar, pageCount=${update.pageCount})');
          setState(() {
            _isNavigating = true;
          });
          unawaited(_webViewController.goToCharIndex(savedCharIndex));
          return;
        }
      } else {
        // No saved position – first open.
        _hasRestoredProgress = true;
        debugPrint('[WebView] RESTORE: No saved position, showing from beginning');
        setState(() {
          _isNavigating = false;
        });
      }
    }

    _scheduleWebViewProgressSave();
    _closeChapterDialog();
    
    // Trigger auto-show latest events after first page load
    if (!_hasTriggeredAutoShowLatestEvents && mounted) {
      _hasTriggeredAutoShowLatestEvents = true;
      // Use a small delay to ensure UI is fully rendered
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _checkAutoShowLatestEvents();
        }
      });
    }
    
    if (kDebugMode) {
      unawaited(_logWebViewPageText(update));
    }
  }

  Future<void> _logWebViewPageText(WebViewPageUpdate update) async {
    final fullText = _webViewFullText;
    if (fullText == null || fullText.isEmpty) {
      return;
    }

    final start = update.startCharIndex ?? 0;
    final end = update.endCharIndex ?? start;
    final expectedCurrent =
        _sliceExpectedTextForLog(fullText, start, end);

    WebViewPageRange? nextInfo;
    if (_webViewController.isReady &&
        update.pageIndex + 1 < update.pageCount) {
      nextInfo = await _webViewController.getPageInfo(update.pageIndex + 1);
    }
    final expectedNext = nextInfo == null
        ? ''
        : _sliceExpectedTextForLog(
            fullText,
            nextInfo.startCharIndex,
            nextInfo.endCharIndex,
          );

    final visibleText = _webViewController.isReady
        ? await _webViewController.getVisibleText()
        : null;

    debugPrint(
      '[WebViewText] page=${update.pageIndex} start=$start end=$end expectedLen=${expectedCurrent.length}',
    );
    debugPrint(
      '[WebViewText] expected: "${_formatLogText(_sanitizeLogText(expectedCurrent))}"',
    );
    if (nextInfo != null) {
      debugPrint(
        '[WebViewText] next page=${nextInfo.pageIndex} start=${nextInfo.startCharIndex} end=${nextInfo.endCharIndex} expectedLen=${expectedNext.length}',
      );
      debugPrint(
        '[WebViewText] expected next: "${_formatLogText(_sanitizeLogText(expectedNext))}"',
      );
    }
    if (visibleText != null && visibleText.trim().isNotEmpty) {
      debugPrint(
        '[WebViewText] visible: "${_formatLogText(_sanitizeLogText(visibleText))}"',
      );
    } else {
      debugPrint('[WebViewText] visible: <empty>');
    }
  }

  String _sliceExpectedTextForLog(String text, int? start, int? end) {
    if (text.isEmpty || start == null || end == null) {
      return '';
    }
    final maxIndex = text.length - 1;
    if (maxIndex < 0) {
      return '';
    }
    final safeStart = start.clamp(0, text.length) as int;
    final safeEnd = end.clamp(0, maxIndex) as int;
    if (safeEnd < safeStart) {
      return '';
    }
    return text.substring(safeStart, safeEnd + 1);
  }

  String _sanitizeLogText(String text) {
    return text
        .replaceAll('\uFFFC', '[img]')
        .replaceAll('\n', '\\n');
  }

  String _formatLogText(String text) {
    const maxLength = 240;
    if (text.length <= maxLength) {
      return text;
    }
    const headLength = 160;
    const tailLength = 60;
    final head = text.substring(0, headLength);
    final tail = text.substring(text.length - tailLength);
    return '$head ... $tail';
  }

  void _handleWebViewTapAction(String action) {
    switch (action) {
      case 'showMenu':
        unawaited(_openReadingMenu());
        break;
      case 'showProgress':
        setState(() {
          _showProgressBar = !_showProgressBar;
        });
        break;
      case 'dismissOverlays':
        if (_showProgressBar) {
          setState(() {
            _showProgressBar = false;
          });
        }
        break;
    }
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
      if (_useWebViewReader) {
        final totalChars = _totalCharacterCount;
        if (totalChars <= 0) {
          return;
        }
        final normalized = percentage.clamp(0.0, 100.0);
        final target = (normalized / 100.0) * (totalChars - 1);
        final rounded = target.round();
        final clamped = rounded.clamp(0, totalChars - 1);
        debugPrint('[ReaderScreen] Jumping to $normalized% -> char index $clamped');
        setState(() {
          _isNavigating = true;
        });
        if (!_webViewController.isReady) {
          _pendingWebViewCharIndex = clamped;
          unawaited(_webViewController.updateLayout());
          return;
        }
        unawaited(_webViewController.goToCharIndex(clamped));
        return;
      }
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
    final theme = Theme.of(context);
    
    // Handle loading state - return early before LayoutBuilder
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _goBackToLibrary,
          ),
          title: Text(widget.book.title, overflow: TextOverflow.ellipsis),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Handle error state - return early before LayoutBuilder
    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _goBackToLibrary,
          ),
          title: const Text('Error'),
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _goBackToLibrary,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back to Library'),
                      ),
                      ElevatedButton.icon(
                        onPressed: _loadBook,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use LayoutBuilder to get actual widget size, especially important for foldable devices
        final actualSize = Size(constraints.maxWidth, constraints.maxHeight);
        _lastActualSize = actualSize;
        final baseMetrics = _computePageMetrics(context, actualSize);
        final metrics = _adjustForUserPadding(baseMetrics);
        _currentPageMetrics = metrics;
        
        // Trigger repagination if size changed significantly
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_useWebViewReader) {
            return;
          }
          if (_docBlocks.isEmpty) return;
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

        if (_useWebViewReader) {
          return _buildWebViewReaderContent(context, actualSize, metrics);
        }
        return _buildReaderContent(context, actualSize, metrics);
      },
    );
  }

  Widget _buildRagIndexingBanner(BuildContext context) {
    if (_ragIndexProgress == null || _ragIndexProgress!.isComplete) {
      return const SizedBox.shrink();
    }

    final isIndexing = _ragIndexProgress!.isIndexing;
    if (!isIndexing) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final progress = _ragIndexProgress!.progressPercentage;
    final totalChunks = _ragIndexProgress!.totalChunks;
    final theme = Theme.of(context);
    final progressLabel = totalChunks == 0
        ? (l10n?.ragIndexingInitializing ?? 'Indexing in progress (...)')
        : (l10n?.ragIndexingProgress(progress.toInt()) ??
            'Indexing in progress (${progress.toInt()}%)');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.primaryContainer,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              progressLabel,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderContent(BuildContext context, Size actualSize, _PageMetrics metrics) {
    final theme = Theme.of(context);

    // Note: Loading and error states are now handled in build() before LayoutBuilder

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
        body: Column(
          children: [
            _buildRagIndexingBanner(context),
            Expanded(
              child: Listener(
                // Listener doesn't participate in gesture arena - it only observes pointer events
                // This allows SelectableText to handle long presses without interference
                // - Long press: handled by SelectableText for text selection (no interference)
                // - Quick tap: detected here for navigation (menu, progress bar, page navigation)
                // - Horizontal swipe: handled by PageView for page navigation
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handlePointerDown,
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
                    // Repagination loading overlay
                    if (_isNavigating || _engine == null || currentPage == null)
                      Positioned.fill(
                        child: Container(
                          color: theme.scaffoldBackgroundColor.withOpacity(0.8),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(
                                  AppLocalizations.of(context)?.repaginating ?? 'Repaginating...',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // Progress indicator overlay
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
          ],
        ),
      ),
    );
  }

  Widget _buildWebViewReaderContent(
    BuildContext context,
    Size actualSize,
    _PageMetrics metrics,
  ) {
    final theme = Theme.of(context);
    final html = _webViewHtml;
    
    if (kDebugMode) {
      debugPrint('[WebView] _buildWebViewReaderContent: html=${html != null ? "present (${html.length} chars)" : "NULL"}, waiting=$_isWaitingForWebViewInit, loading=$_isLoading, ready=${_webViewController.isReady}');
    }
    
    if (html == null) {
      debugPrint('[WebView] HTML is NULL, returning empty widget');
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final defaultActionLabel = l10n?.textSelectionDefaultLabel ?? 'Translate';
    final actionLabel = (_selectionActionLabel ?? defaultActionLabel).trim().isEmpty
        ? defaultActionLabel
        : _selectionActionLabel!;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateWebViewAppearance(metrics, theme, actionLabel);
      final layoutKey = _computeLayoutKey(metrics);
      if (_webViewController.isReady && _lastWebViewLayoutKey != layoutKey) {
        if (kDebugMode) {
          debugPrint('[WebView] Layout key changed: old=$_lastWebViewLayoutKey, new=$layoutKey - triggering updateLayout()');
        }
        _lastWebViewLayoutKey = layoutKey;
        unawaited(_webViewController.updateLayout());
      } else if (kDebugMode && _webViewController.isReady) {
        debugPrint('[WebView] Layout key unchanged: $layoutKey - skipping updateLayout()');
      }
    });

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            key: _webViewKey,
            child: WebViewReader(
              html: html,
              controller: _webViewController,
              onPageChanged: _handleWebViewPageChanged,
              onSelectionChanged: _handleWebViewSelectionChanged,
              onSelectionAction: _handleSelectionAction,
              onTapAction: _handleWebViewTapAction,
            ),
          ),
          if (_webViewSelection != null) _buildWebViewSelectionToolbar(),
          if (_isNavigating || html.isEmpty || _isWaitingForWebViewInit)
            Positioned.fill(
              child: Container(
                color: theme.scaffoldBackgroundColor.withOpacity(0.8),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context)?.repaginating ??
                            'Repaginating...',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
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

  void _updateWebViewAppearance(
    _PageMetrics metrics,
    ThemeData theme,
    String actionLabel,
  ) {
    if (!_webViewController.isAttached || !_webViewController.isReady) {
      return;
    }
    final fontSize = metrics.baseTextStyle.fontSize ?? _defaultReaderFontSize;
    final lineHeight = metrics.baseTextStyle.height ?? 1.6;
    final styleKey = [
      fontSize.toStringAsFixed(2),
      lineHeight.toStringAsFixed(2),
      theme.colorScheme.onSurface.value.toRadixString(16),
      theme.scaffoldBackgroundColor.value.toRadixString(16),
      _horizontalPadding.toStringAsFixed(1),
      _verticalPadding.toStringAsFixed(1),
    ].join('|');
    if (_lastWebViewStyleKey != styleKey) {
      _lastWebViewStyleKey = styleKey;
      _stylesAppliedForRestore = true; // Layout will reflect our styles; safe to restore after next page update
      unawaited(_webViewController.updateStyles(
        fontSize: fontSize,
        lineHeight: lineHeight,
        textColor: theme.colorScheme.onSurface,
        backgroundColor: theme.scaffoldBackgroundColor,
        paddingX: _horizontalPadding,
        paddingY: _verticalPadding,
      ));
    }

    if (_lastWebViewActionLabel != actionLabel) {
      _lastWebViewActionLabel = actionLabel;
      unawaited(_webViewController.updateActionLabel(actionLabel));
    }

    final actionEnabled = !_isProcessingSelection;
    if (_lastWebViewActionEnabled != actionEnabled) {
      _lastWebViewActionEnabled = actionEnabled;
      unawaited(_webViewController.setActionEnabled(actionEnabled));
    }
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

  Widget _buildWebViewSelectionToolbar() {
    final selection = _webViewSelection;
    if (selection == null || selection.text.isEmpty) {
      return const SizedBox.shrink();
    }

    final webViewBox = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (webViewBox == null) {
      return const SizedBox.shrink();
    }

    if (selection.rect.width <= 0 || selection.rect.height <= 0) {
      return const SizedBox.shrink();
    }

    // WebView and overlay share same coordinate space (Positioned.fill wraps WebView)
    final globalTopLeft = webViewBox.localToGlobal(selection.rect.topLeft);
    final localTopLeft = webViewBox.globalToLocal(globalTopLeft);
    final localRect = Rect.fromLTWH(
      localTopLeft.dx,
      localTopLeft.dy,
      selection.rect.width,
      selection.rect.height,
    );

    final l10n = AppLocalizations.of(context);
    final defaultActionLabel = l10n?.textSelectionDefaultLabel ?? 'Translate';
    final actionLabel = (_selectionActionLabel ?? defaultActionLabel).trim().isEmpty
        ? defaultActionLabel
        : (_selectionActionLabel ?? defaultActionLabel);
    final materialL10n = MaterialLocalizations.of(context);

    final items = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: actionLabel,
        onPressed: _isProcessingSelection
            ? null
            : () {
                final text = selection.text;
                _clearSelectionCallback?.call();
                _clearSelectionCallback = null;
                _handleSelectionAction(text);
              },
      ),
      ContextMenuButtonItem(
        label: materialL10n.copyButtonLabel,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: selection.text));
          _clearSelectionCallback?.call();
          _clearSelectionCallback = null;
        },
      ),
      ContextMenuButtonItem(
        label: materialL10n.selectAllButtonLabel,
        onPressed: () {
          unawaited(_webViewController.selectAll());
        },
      ),
    ];

    return Positioned.fill(
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: localRect.topCenter),
        buttonItems: items,
      ),
    );
  }

  String? get _currentChapterTitle {
    if (_useWebViewReader) {
      final chapterIndex = _currentChapterIndex;
      if (chapterIndex == null) return null;
      if (chapterIndex < 0 || chapterIndex >= _chapterEntries.length) return null;
      return _chapterEntries[chapterIndex].title;
    }
    if (_engine == null) return null;
    final page = _engine!.getPage(_currentPageIndex);
    final chapterIndex = page?.chapterIndex;
    if (chapterIndex == null) return null;
    if (chapterIndex < 0 || chapterIndex >= _chapterEntries.length) return null;
    return _chapterEntries[chapterIndex].title;
  }

  int? _resolveChapterIndexForChar(int charIndex) {
    if (_chapterCharOffsets.isEmpty) {
      return null;
    }
    var low = 0;
    var high = _chapterCharOffsets.length - 1;
    var result = _chapterCharOffsets.first.chapterIndex;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final offset = _chapterCharOffsets[mid].startChar;
      if (offset <= charIndex) {
        result = _chapterCharOffsets[mid].chapterIndex;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
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

  Future<void> _openReadingMenu() async {
    final count =
        await _translationDatabase.getTranslationsCount(widget.book.id);
    if (!mounted) return;

    final action = await showReaderMenu(
      context: context,
      fontScale: _fontScale,
      onFontScaleChanged: _updateFontScale,
      hasChapters: _chapterEntries.isNotEmpty,
      hasSavedWords: count > 0,
      bookId: widget.book.id,
    );
    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case ReaderMenuAction.goToChapter:
        _showChapterSelector();
        break;
      case ReaderMenuAction.goToPercentage:
        _showGoToPercentageDialog();
        break;
      case ReaderMenuAction.showSavedWords:
        _showSavedWords();
        break;
      case ReaderMenuAction.openSettings:
        unawaited(_openSettings());
        break;
      case ReaderMenuAction.showSummaryFromBeginning:
        _openSummary(SummaryType.fromBeginning);
        break;
      case ReaderMenuAction.showCharactersSummary:
        _openSummary(SummaryType.characters);
        break;
      case ReaderMenuAction.deleteSummaries:
        unawaited(_confirmAndDeleteSummaries());
        break;
      case ReaderMenuAction.askQuestion:
        _showRagQuestionDialog();
        break;
      case ReaderMenuAction.showLatestEvents:
        _showLatestEventsDialog();
        break;
      case ReaderMenuAction.returnToLibrary:
        unawaited(_returnToLibrary());
        break;
    }
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

  Future<void> _showRagQuestionDialog() async {
    if (!mounted) return;

    // Check if book is indexed
    final isIndexed = await _ragQueryService.isBookIndexed(widget.book.id);
    if (!isIndexed) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.ragNotIndexed),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // Show question dialog
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (context) => _RagQuestionDialog(
        bookId: widget.book.id,
        currentCharPosition: _currentCharacterIndex,
        ragQueryService: _ragQueryService,
        summaryService: _summaryService,
        l10n: l10n,
      ),
    );
  }

  Future<void> _showLatestEventsDialog() async {
    if (!mounted) return;

    // Check if book is indexed
    final isIndexed = await _ragQueryService.isBookIndexed(widget.book.id);
    if (!isIndexed) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.ragNotIndexed),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // Show latest events dialog
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (context) => _LatestEventsDialog(
        bookId: widget.book.id,
        currentCharPosition: _currentCharacterIndex,
        summaryService: _summaryService,
        l10n: l10n,
      ),
    );
  }

  /// Check if we should auto-show the latest events dialog
  Future<void> _checkAutoShowLatestEvents() async {
    if (!mounted) return;

    // Check if auto-show is enabled for this book
    final shouldShow = await _settingsService.getAutoShowLatestEvents(widget.book.id);
    if (!shouldShow) return;

    // Check if book is indexed
    final isIndexed = await _ragQueryService.isBookIndexed(widget.book.id);
    if (!isIndexed) return;

    // Check if there are enough chunks to show
    final latestEventsService = LatestEventsService();
    final hasEnough = await latestEventsService.hasEnoughChunks(
      bookId: widget.book.id,
      currentCharPosition: _currentCharacterIndex,
      minChunks: 1,
    );
    
    if (!hasEnough) return;

    // Show the dialog automatically
    if (!mounted) return;
    await _showLatestEventsDialog();
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
      openLibrary: () => Navigator.of(context, rootNavigator: true)
          .pushNamedAndRemoveUntil(libraryRoute, (_) => false),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const SettingsScreen(),
      ),
    );
    if (!mounted) return;
    await _initializeSummaryService();
    await _loadSelectionActionConfig();
    await _refreshReaderLayoutFromSettings();
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
    if (_useWebViewReader) {
      if (chapterIndex < 0) {
        _clearNavigatingState();
        _closeChapterDialog();
        return;
      }
      _ChapterOffset? targetOffset;
      for (final offset in _chapterCharOffsets) {
        if (offset.chapterIndex == chapterIndex) {
          targetOffset = offset;
          break;
        }
      }
      if (targetOffset == null) {
        _clearNavigatingState();
        _closeChapterDialog();
        return;
      }
      final targetCharIndex = targetOffset.startChar;
      setState(() {
        _isNavigating = true;
        _navigatingToChapterIndex = chapterIndex;
      });
      if (!_webViewController.isReady) {
        _pendingWebViewCharIndex = targetCharIndex;
        unawaited(_webViewController.updateLayout());
        return;
      }
      unawaited(_webViewController.goToCharIndex(targetCharIndex));
      return;
    }
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

  void _showSavedWords() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SavedWordsScreen(book: widget.book),
      ),
    );
  }

  void _openSummary(SummaryType summaryType) async {
    if (_useWebViewReader) {
      if (_currentCharacterIndex <= 0 && _totalCharacterCount <= 0) {
        return;
      }

      if (!await _ensureSummaryServiceReady()) {
        return;
      }

      final visibleIndex = _lastVisibleCharacterIndex ?? _currentCharacterIndex;
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentCharacterIndex: _currentCharacterIndex,
        lastVisibleCharacterIndex: visibleIndex,
        progress: _progress,
        lastRead: DateTime.now(),
      );

      final engineFullText = _webViewFullText ?? '';
      if (engineFullText.isEmpty) {
        return;
      }

      unawaited(_updateLastReadingStopOnExit());

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
      return;
    }
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

    _clearSelectionCallback?.call();
    _clearSelectionCallback = null;

    // Clear selection state
    setState(() {
      _isProcessingSelection = true;
      _hasActiveSelection = false;
      _lastSelectionChangeTimestamp = null;
      _webViewSelection = null;
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

      // Parse the structured response
      final parsedResult = _parseSelectionActionResult(
        originalText: trimmed,
        generatedText: response.trim(),
      );

      await _showSelectionResultDialog(
        originalText: trimmed,
        generatedText: response.trim(),
        actionLabel: label,
        parsedOriginal: parsedResult.originalFromResponse,
        pronunciation: parsedResult.pronunciation,
        translation: parsedResult.translation,
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

  Future<void> _saveTranslation({
    required String original,
    required String pronunciation,
    required String translation,
  }) async {
    final savedTranslation = SavedTranslation(
      bookId: widget.book.id,
      original: original,
      pronunciation: pronunciation,
      translation: translation,
      createdAt: DateTime.now(),
    );
    
    await _translationDatabase.saveTranslation(savedTranslation);
  }

  Future<void> _showSelectionResultDialog({
    required String originalText,
    required String generatedText,
    required String actionLabel,
    String? parsedOriginal,
    String? pronunciation,
    String? translation,
  }) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (context) {
        final screenHeight = MediaQuery.of(context).size.height;
        final maxDialogHeight = screenHeight * 0.75; // Use 75% of screen height
        
        return Dialog(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: maxDialogHeight,
            ),
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
                  const SizedBox(height: 16),
                  Text(
                    l10n.textSelectionSelectedTextLabel,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
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
                  const SizedBox(height: 20),
                  Flexible(
                    fit: FlexFit.loose,
                    child: SingleChildScrollView(
                      child: _buildSelectionResultContent(
                        context: context,
                        generatedText: generatedText,
                        parsedOriginal: parsedOriginal,
                        pronunciation: pronunciation,
                        translation: translation,
                      ),
                    ),
                  ),
                  if (pronunciation != null && translation != null) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          _saveTranslation(
                            original: originalText,
                            pronunciation: pronunciation,
                            translation: translation,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.translationSaved),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.bookmark_add),
                        label: Text(l10n.saveTranslation),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Parse a structured response of the form:
  /// Original: ...
  /// Pronunciation: ...
  /// Translation: ...
  ///
  /// Falls back gracefully when the format is not respected.
  _ParsedSelectionActionResult _parseSelectionActionResult({
    required String originalText,
    required String generatedText,
  }) {
    final lines = generatedText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    String? originalFromResponse;
    String? pronunciation;
    String? translation;

    for (final line in lines) {
      if (line.startsWith('Original:')) {
        originalFromResponse =
            line.substring('Original:'.length).trim();
      } else if (line.startsWith('Pronunciation:')) {
        pronunciation =
            line.substring('Pronunciation:'.length).trim();
      } else if (line.startsWith('Translation:')) {
        translation =
            line.substring('Translation:'.length).trim();
      }
    }

    // If translation is missing but we have some content, treat the whole
    // response as the translation to avoid losing information.
    translation ??= generatedText.trim().isNotEmpty
        ? generatedText.trim()
        : null;

    // For original, prefer the model's echo if present, otherwise the
    // user's selected text.
    originalFromResponse ??=
        originalText.trim().isNotEmpty ? originalText.trim() : null;

    return _ParsedSelectionActionResult(
      originalFromResponse: originalFromResponse,
      pronunciation:
          pronunciation != null && pronunciation.isNotEmpty
              ? pronunciation
              : null,
      translation: translation != null && translation.isNotEmpty
          ? translation
          : null,
    );
  }

  /// Build the widget that displays the result of the selection action.
  /// If structured fields are available, show them as separate labeled
  /// sections; otherwise fall back to the raw generated text.
  Widget _buildSelectionResultContent({
    required BuildContext context,
    required String generatedText,
    String? parsedOriginal,
    String? pronunciation,
    String? translation,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final hasStructured = pronunciation != null || translation != null;

    if (!hasStructured) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(generatedText),
      );
    }

    final children = <Widget>[];

    // Don't display the "Original:" section - it's already shown above
    
    if (pronunciation != null) {
      children.add(
        Text(
          l10n.pronunciation,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      );
      children.add(const SizedBox(height: 8));
      children.add(
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(pronunciation),
        ),
      );
      children.add(const SizedBox(height: 16));
    }

    if (translation != null) {
      children.add(
        Text(
          l10n.translation,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      );
      children.add(const SizedBox(height: 8));
      children.add(
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(translation),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
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

  _WebViewDocument _buildWebViewDocument(EpubBook epub) {
    final chapterOffsets = <_ChapterOffset>[];
    var totalCharacters = 0;
    final contentBuffer = StringBuffer();
    final cssBuffer = StringBuffer();
    final fullTextBuffer = StringBuffer();

    final resources = _collectByteResources(epub);
    final cssFiles = epub.Content?.Css;
    if (cssFiles != null) {
      for (final entry in cssFiles.entries) {
        final cssContent = entry.value.Content;
        if (cssContent != null && cssContent.isNotEmpty) {
          cssBuffer.writeln(_rewriteCssUrls(cssContent.toString(), resources));
        }
      }
    }

    final epubChapters = epub.Chapters ?? const <EpubChapter>[];
    for (var i = 0; i < epubChapters.length; i++) {
      final chapter = epubChapters[i];
      final html = chapter.HtmlContent ?? '';
      if (html.isEmpty) {
        continue;
      }

      final document = html_parser.parse(html);
      final styleTags = document.querySelectorAll('style');
      for (final styleTag in styleTags) {
        final cssContent = styleTag.text;
        if (cssContent.isNotEmpty) {
          cssBuffer.writeln(_rewriteCssUrls(cssContent, resources));
        }
        styleTag.remove();
      }
      for (final link in document.querySelectorAll('link')) {
        link.remove();
      }
      for (final script in document.querySelectorAll('script')) {
        script.remove();
      }

      for (final img in document.getElementsByTagName('img')) {
        final src = img.attributes['src'];
        if (src == null || src.isEmpty) continue;
        final dataUri = _resolveResourceDataUri(src, resources);
        if (dataUri != null) {
          img.attributes['src'] = dataUri;
        }
      }
      for (final image in document.getElementsByTagName('image')) {
        final href = image.attributes['xlink:href'] ?? image.attributes['href'];
        if (href == null || href.isEmpty) continue;
        final dataUri = _resolveResourceDataUri(href, resources);
        if (dataUri != null) {
          if (image.attributes.containsKey('xlink:href')) {
            image.attributes['xlink:href'] = dataUri;
          } else {
            image.attributes['href'] = dataUri;
          }
        }
      }

      final body = document.body;
      if (body == null) {
        continue;
      }

      final normalizedText = HtmlTextExtractor.extract(html);
      chapterOffsets.add(
        _ChapterOffset(
          chapterIndex: i,
          startChar: totalCharacters,
        ),
      );
      totalCharacters += normalizedText.length;
      fullTextBuffer.write(normalizedText);

      contentBuffer.writeln(
        '<section class="chapter" data-chapter-index="$i">${body.innerHtml}</section>',
      );
    }

    if (contentBuffer.isEmpty) {
      contentBuffer.writeln('<p>Aucun contenu lisible dans ce livre.</p>');
    }

    final htmlBuffer = StringBuffer()
      ..writeln('<!DOCTYPE html>')
      ..writeln('<html>')
      ..writeln('<head>')
      ..writeln('<meta charset="utf-8">')
      ..writeln(
        '<meta name="viewport" content="width=device-width, height=device-height, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">',
      )
      ..writeln('<style>')
      ..writeln(_webViewBaseCss)
      ..writeln(cssBuffer.toString())
      ..writeln('</style>')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('<div id="reader">')
      ..writeln(contentBuffer.toString())
      ..writeln('</div>')
      ..writeln(_webViewSelectionMenuHtml)
      ..writeln('<script>')
      ..writeln(_webViewReaderScript)
      ..writeln('</script>')
      ..writeln('</body>')
      ..writeln('</html>');

    return _WebViewDocument(
      html: htmlBuffer.toString(),
      chapterCharOffsets: chapterOffsets,
      totalCharacters: totalCharacters,
      fullText: fullTextBuffer.toString(),
    );
  }

  Map<String, EpubByteContentFile> _collectByteResources(EpubBook epub) {
    final resources = <String, EpubByteContentFile>{};
    final images = epub.Content?.Images;
    if (images != null) {
      resources.addAll(images);
    }
    final fonts = epub.Content?.Fonts;
    if (fonts != null) {
      resources.addAll(fonts);
    }
    final allFiles = epub.Content?.AllFiles;
    if (allFiles != null) {
      for (final entry in allFiles.entries) {
        final file = entry.value;
        if (file is EpubByteContentFile) {
          resources.putIfAbsent(entry.key, () => file);
        }
      }
    }
    return resources;
  }

  String _rewriteCssUrls(
    String css,
    Map<String, EpubByteContentFile> resources,
  ) {
    final urlPattern = RegExp(r'url\(([^)]+)\)', caseSensitive: false);
    return css.replaceAllMapped(urlPattern, (match) {
      var raw = (match.group(1) ?? '').trim();
      if (raw.startsWith('"') && raw.endsWith('"') && raw.length > 1) {
        raw = raw.substring(1, raw.length - 1);
      } else if (raw.startsWith("'") && raw.endsWith("'") && raw.length > 1) {
        raw = raw.substring(1, raw.length - 1);
      }
      if (raw.startsWith('data:') ||
          raw.startsWith('http:') ||
          raw.startsWith('https:') ||
          raw.startsWith('#')) {
        return match.group(0) ?? '';
      }
      final dataUri = _resolveResourceDataUri(raw, resources);
      if (dataUri == null) {
        return match.group(0) ?? '';
      }
      return "url('$dataUri')";
    });
  }

  String? _resolveResourceDataUri(
    String src,
    Map<String, EpubByteContentFile> resources,
  ) {
    final normalized = _normalizeResourcePath(src);
    if (normalized.isEmpty) {
      return null;
    }
    final fragment = normalized.split('/').last;
    for (final entry in resources.entries) {
      final key = _normalizeResourcePath(entry.key);
      if (key.endsWith(fragment) || fragment.endsWith(key)) {
        final data = entry.value.Content;
        if (data == null || data.isEmpty) {
          return null;
        }
        final mime = entry.value.ContentMimeType ??
            _guessMimeType(entry.key) ??
            _guessMimeType(normalized) ??
            'application/octet-stream';
        final encoded = base64Encode(data);
        return 'data:$mime;base64,$encoded';
      }
    }
    return null;
  }

  String _normalizeResourcePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    final hashIndex = normalized.indexOf('#');
    if (hashIndex != -1) {
      normalized = normalized.substring(0, hashIndex);
    }
    final queryIndex = normalized.indexOf('?');
    if (queryIndex != -1) {
      normalized = normalized.substring(0, queryIndex);
    }
    while (normalized.startsWith('../')) {
      normalized = normalized.substring(3);
    }
    return normalized;
  }

  String? _guessMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.ttf')) return 'font/ttf';
    if (lower.endsWith('.otf')) return 'font/otf';
    if (lower.endsWith('.woff')) return 'font/woff';
    if (lower.endsWith('.woff2')) return 'font/woff2';
    return null;
  }

  static const String _webViewBaseCss = '''
:root {
  --reader-font-size: 16px;
  --reader-line-height: 1.6;
  --reader-text-color: #111111;
  --reader-bg-color: #ffffff;
  --reader-padding-x: 30px;
  --reader-padding-y: 50px;
  --page-width: 100vw;
  --page-height: 100vh;
}
html,
body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
}
body {
  font-size: var(--reader-font-size);
  line-height: var(--reader-line-height);
  color: var(--reader-text-color);
  background: var(--reader-bg-color);
  padding: var(--reader-padding-y) var(--reader-padding-x);
  box-sizing: border-box;
  -webkit-text-size-adjust: none;
  -webkit-touch-callout: none;
  -webkit-user-select: text;
  user-select: text;
}
#reader {
  width: var(--page-width);
  height: var(--page-height);
  column-width: var(--page-width);
  column-gap: 0;
  column-fill: auto;
  box-sizing: border-box;
  overflow-x: auto;
  overflow-y: hidden;
  scroll-behavior: auto;
}
#reader img,
#reader svg {
  max-width: 100%;
  height: auto;
}
.chapter {
  break-before: page;
  page-break-before: always;
  -webkit-column-break-before: always;
}
.chapter:first-child {
  break-before: auto;
  page-break-before: auto;
  -webkit-column-break-before: auto;
}
#selection-menu {
  position: fixed;
  z-index: 9999;
  display: none !important;
  background: rgba(20, 20, 20, 0.9);
  color: #ffffff;
  border-radius: 10px;
  padding: 6px;
  box-shadow: 0 6px 18px rgba(0, 0, 0, 0.3);
  gap: 4px;
  align-items: center;
  white-space: nowrap;
}
#selection-menu button {
  appearance: none;
  border: none;
  background: transparent;
  color: inherit;
  font-size: 14px;
  padding: 6px 10px;
  cursor: pointer;
}
#selection-menu button[disabled] {
  opacity: 0.5;
}
::-webkit-scrollbar {
  display: none;
}
::selection {
  background: rgba(233, 30, 99, 0.35);
  color: inherit;
}
''';

  static const String _webViewSelectionMenuHtml = '''
<div id="selection-menu">
  <button id="selection-action" type="button">Translate</button>
  <button id="selection-copy" type="button">Copier</button>
  <button id="selection-select-all" type="button">Tout sélectionner</button>
</div>
''';

  static const String _webViewReaderScript = '''
(function() {
  const CHANNEL_NAME = 'MemoReader';
  const reader = document.getElementById('reader');
  const selectionMenu = document.getElementById('selection-menu');
  const selectionButton = document.getElementById('selection-action');
  const selectionCopy = document.getElementById('selection-copy');
  const selectionSelectAll = document.getElementById('selection-select-all');
  const selectionPadding = 8;

  let viewportWidth = 0;
  let viewportHeight = 0;
  let pageWidth = 0;
  let pageHeight = 0;
  let contentLeft = 0;
  let contentTop = 0;
  let paddingX = 0;
  let paddingY = 0;
  let pageStride = 0;
  let pageCount = 1;
  let currentPage = 0;
  let requestedPage = 0;
  let totalChars = null;
  let lastStartChar = 0;
  let lastEndChar = 0;
  let actionEnabled = true;
  let selectionTimer = null;
  let touchStart = null;
  let lastTouchTime = 0;
  let pageChangeQueue = Promise.resolve();
  let pageChangeToken = 0;

  function getScrollContainer() {
    return reader || document.scrollingElement || document.documentElement;
  }

  function getPageStride() {
    if (reader && window.getComputedStyle) {
      const style = window.getComputedStyle(reader);
      const columnWidth = parseFloat(style.columnWidth);
      const columnGap = parseFloat(style.columnGap);
      const width = Number.isFinite(columnWidth) ? columnWidth : pageWidth;
      const gap = Number.isFinite(columnGap) ? columnGap : 0;
      const stride = width + gap;
      if (stride > 0) {
        return stride;
      }
    }
    return pageWidth;
  }

  function postMessage(payload) {
    if (window[CHANNEL_NAME] && window[CHANNEL_NAME].postMessage) {
      window[CHANNEL_NAME].postMessage(JSON.stringify(payload));
    }
  }

  function normalizeWhitespace(text) {
    let normalized = text.replace(/\\r\\n/g, '\\n').replace(/\\r/g, '\\n');
    normalized = normalized.replace(/\\u00a0/g, ' ');
    normalized = normalized.replace(/[ \\t]+/g, ' ');
    normalized = normalized.replace(/\\n{3,}/g, '\\n\\n');
    return normalized.trim();
  }

  function isLayoutArtifact(element) {
    const classAttr = (element.getAttribute('class') || '').toLowerCase();
    if (classAttr.indexOf('pagebreak') !== -1 || classAttr.indexOf('pagenum') !== -1) {
      return true;
    }

    const style = (element.getAttribute('style') || '').toLowerCase();
    if (style.indexOf('page-break') !== -1 ||
        style.indexOf('break-before') !== -1 ||
        style.indexOf('break-after') !== -1) {
      return true;
    }
    if (style.indexOf('position:absolute') !== -1 || style.indexOf('position: fixed') !== -1) {
      return true;
    }
    if (/(width|height)\\s*:\\s*\\d+px/.test(style)) {
      return true;
    }
    if (/\\b(top|left|right|bottom)\\s*:/.test(style)) {
      return true;
    }
    return false;
  }

  function updateLayoutMetrics() {
    viewportWidth = window.innerWidth || document.documentElement.clientWidth;
    viewportHeight = window.innerHeight || document.documentElement.clientHeight;
    const rootStyle = window.getComputedStyle(document.documentElement);
    paddingX = parseFloat(rootStyle.getPropertyValue('--reader-padding-x')) || 0;
    paddingY = parseFloat(rootStyle.getPropertyValue('--reader-padding-y')) || 0;
    contentLeft = paddingX;
    contentTop = paddingY;
    pageWidth = Math.max(0, viewportWidth - paddingX * 2);
    pageHeight = Math.max(0, viewportHeight - paddingY * 2);
    document.documentElement.style.setProperty('--page-width', pageWidth + 'px');
    document.documentElement.style.setProperty('--page-height', pageHeight + 'px');
    pageStride = getPageStride();
    const scrollElement = getScrollContainer();
    if (scrollElement) {
      pageCount = Math.max(1, Math.ceil(scrollElement.scrollWidth / pageStride));
    } else {
      pageCount = 1;
    }
  }

  function waitForImages() {
    const images = Array.from(document.images || []);
    if (images.length === 0) {
      return Promise.resolve();
    }
    const promises = images.map(function(img) {
      if (img.complete) {
        return Promise.resolve();
      }
      return new Promise(function(resolve) {
        img.addEventListener('load', resolve, { once: true });
        img.addEventListener('error', resolve, { once: true });
      });
    });
    return Promise.all(promises);
  }

  function waitForFonts() {
    if (document.fonts && document.fonts.ready) {
      return document.fonts.ready.catch(function() {});
    }
    return Promise.resolve();
  }

  function getRangeFromPoint(x, y) {
    if (document.caretRangeFromPoint) {
      return document.caretRangeFromPoint(x, y);
    }
    if (document.caretPositionFromPoint) {
      const pos = document.caretPositionFromPoint(x, y);
      if (!pos) {
        return null;
      }
      const range = document.createRange();
      range.setStart(pos.offsetNode, pos.offset);
      range.collapse(true);
      return range;
    }
    return null;
  }

  function resolveRangePosition(range) {
    if (!range) {
      return null;
    }
    let node = range.startContainer;
    let offset = range.startOffset;
    if (node.nodeType === Node.TEXT_NODE) {
      if (reader && !reader.contains(node)) {
        return null;
      }
      return { node: node, offset: offset };
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return null;
    }
    const element = node;
    const child = element.childNodes[offset] || element.childNodes[element.childNodes.length - 1];
    if (!child) {
      return null;
    }
    const walker = document.createTreeWalker(child, NodeFilter.SHOW_TEXT, null);
    const textNode = walker.nextNode();
    if (!textNode) {
      return null;
    }
    if (reader && !reader.contains(textNode)) {
      return null;
    }
    return { node: textNode, offset: 0 };
  }

  function findTextNodeInElement(element) {
    if (!element) {
      return null;
    }
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
    return walker.nextNode();
  }

  function computeCharCount(targetNode, targetOffset) {
    let count = 0;
    let pendingParagraphBreak = false;
    let lastChar = '';
    let secondLastChar = '';
    let done = false;

    function appendText(text) {
      if (!text) {
        return;
      }
      count += text.length;
      const prevLast = lastChar;
      if (text.length >= 2) {
        secondLastChar = text[text.length - 2];
        lastChar = text[text.length - 1];
      } else {
        secondLastChar = prevLast;
        lastChar = text[text.length - 1];
      }
    }

    function scheduleParagraphBreak() {
      pendingParagraphBreak = true;
    }

    function flushPendingBreak() {
      if (pendingParagraphBreak && count > 0) {
        if (secondLastChar === '\\n' && lastChar === '\\n') {
          // Paragraph break already present.
        } else if (lastChar === '\\n') {
          appendText('\\n');
        } else {
          appendText('\\n\\n');
        }
      }
      pendingParagraphBreak = false;
    }

    function ensureParagraphBoundary() {
      if (count > 0) {
        flushPendingBreak();
      }
    }

    function walk(node) {
      if (done || !node) {
        return;
      }
      if (node.nodeType === Node.ELEMENT_NODE) {
        const element = node;
        if (isLayoutArtifact(element)) {
          return;
        }
        const name = (element.tagName || '').toLowerCase();
        switch (name) {
          case 'style':
          case 'script':
            return;
          case 'br':
            appendText('\\n');
            return;
          case 'img':
            flushPendingBreak();
            appendText('\\uFFFC');
            scheduleParagraphBreak();
            return;
          case 'ul':
          case 'ol': {
            ensureParagraphBoundary();
            const ordered = name === 'ol';
            let counter = 1;
            const items = Array.from(element.children).filter(function(child) {
              return (child.tagName || '').toLowerCase() === 'li';
            });
            for (let i = 0; i < items.length; i++) {
              const item = items[i];
              const bullet = ordered ? (counter + '. ') : '• ';
              if (targetNode && item.contains(targetNode)) {
                const range = document.createRange();
                range.setStart(item, 0);
                range.setEnd(targetNode, targetOffset);
                const partial = normalizeWhitespace(range.toString());
                if (partial) {
                  appendText(bullet + partial);
                }
                done = true;
                return;
              }
              const text = normalizeWhitespace(item.textContent || '');
              if (text) {
                appendText(bullet + text);
                appendText('\\n');
              }
              counter += 1;
            }
            scheduleParagraphBreak();
            return;
          }
          case 'h1':
          case 'h2':
          case 'h3':
          case 'h4':
          case 'h5':
          case 'h6':
          case 'p':
          case 'div':
          case 'section':
          case 'article':
          case 'blockquote':
          case 'pre':
            ensureParagraphBoundary();
            Array.from(element.childNodes).forEach(walk);
            scheduleParagraphBreak();
            return;
          default:
            Array.from(element.childNodes).forEach(walk);
            return;
        }
      }
      if (node.nodeType === Node.TEXT_NODE) {
        const textValue = node.nodeValue || '';
        if (targetNode && node === targetNode) {
          const partial = normalizeWhitespace(textValue.substring(0, targetOffset));
          appendText(partial);
          pendingParagraphBreak = false;
          done = true;
          return;
        }
        const cleaned = normalizeWhitespace(textValue);
        appendText(cleaned);
        pendingParagraphBreak = false;
        return;
      }
      Array.from(node.childNodes || []).forEach(walk);
    }

    if (reader) {
      walk(reader);
    }
    if (!done) {
      flushPendingBreak();
    }
    return count;
  }

  function computeCharCountToImage(targetImage) {
    let count = 0;
    let pendingParagraphBreak = false;
    let lastChar = '';
    let secondLastChar = '';
    let done = false;

    function appendText(text) {
      if (!text) {
        return;
      }
      count += text.length;
      const prevLast = lastChar;
      if (text.length >= 2) {
        secondLastChar = text[text.length - 2];
        lastChar = text[text.length - 1];
      } else {
        secondLastChar = prevLast;
        lastChar = text[text.length - 1];
      }
    }

    function scheduleParagraphBreak() {
      pendingParagraphBreak = true;
    }

    function flushPendingBreak() {
      if (pendingParagraphBreak && count > 0) {
        if (secondLastChar === '\\n' && lastChar === '\\n') {
          // Paragraph break already present.
        } else if (lastChar === '\\n') {
          appendText('\\n');
        } else {
          appendText('\\n\\n');
        }
      }
      pendingParagraphBreak = false;
    }

    function ensureParagraphBoundary() {
      if (count > 0) {
        flushPendingBreak();
      }
    }

    function walk(node) {
      if (done || !node) {
        return;
      }
      if (node.nodeType === Node.ELEMENT_NODE) {
        const element = node;
        if (isLayoutArtifact(element)) {
          return;
        }
        const name = (element.tagName || '').toLowerCase();
        if (element === targetImage && (name === 'img' || name === 'image')) {
          flushPendingBreak();
          done = true;
          return;
        }
        switch (name) {
          case 'style':
          case 'script':
            return;
          case 'br':
            appendText('\\n');
            return;
          case 'img':
            flushPendingBreak();
            appendText('\\uFFFC');
            scheduleParagraphBreak();
            return;
          case 'ul':
          case 'ol': {
            ensureParagraphBoundary();
            const ordered = name === 'ol';
            let counter = 1;
            const items = Array.from(element.children).filter(function(child) {
              return (child.tagName || '').toLowerCase() === 'li';
            });
            for (let i = 0; i < items.length; i++) {
              const item = items[i];
              const bullet = ordered ? (counter + '. ') : '• ';
              const text = normalizeWhitespace(item.textContent || '');
              if (text) {
                appendText(bullet + text);
                appendText('\\n');
              }
              counter += 1;
            }
            scheduleParagraphBreak();
            return;
          }
          case 'h1':
          case 'h2':
          case 'h3':
          case 'h4':
          case 'h5':
          case 'h6':
          case 'p':
          case 'div':
          case 'section':
          case 'article':
          case 'blockquote':
          case 'pre':
            ensureParagraphBoundary();
            Array.from(element.childNodes).forEach(walk);
            scheduleParagraphBreak();
            return;
          default:
            Array.from(element.childNodes).forEach(walk);
            return;
        }
      }
      if (node.nodeType === Node.TEXT_NODE) {
        const textValue = node.nodeValue || '';
        const cleaned = normalizeWhitespace(textValue);
        appendText(cleaned);
        pendingParagraphBreak = false;
        return;
      }
      Array.from(node.childNodes || []).forEach(walk);
    }

    if (reader) {
      walk(reader);
    }
    if (!done) {
      flushPendingBreak();
    }
    return count;
  }

  function charIndexAtPoint(x, y) {
    const range = getRangeFromPoint(x, y);
    const resolved = resolveRangePosition(range);
    if (resolved) {
      return computeCharCount(resolved.node, resolved.offset);
    }
    const element = document.elementFromPoint(x, y);
    if (!element) {
      return null;
    }
    if (reader && !reader.contains(element)) {
      return null;
    }
    if (element === reader) {
      return null;
    }
    const imageElement = element.closest ? element.closest('img, image') : null;
    if (imageElement && (!reader || reader.contains(imageElement))) {
      return computeCharCountToImage(imageElement);
    }
    const textNode = findTextNodeInElement(element);
    if (textNode) {
      return computeCharCount(textNode, 0);
    }
    return null;
  }

  function findCharIndexInColumn(xCandidates, yStart, yEnd, step) {
    const direction = yEnd >= yStart ? 1 : -1;
    const stepSize = Math.max(8, Math.round(step));
    for (
      let y = yStart;
      direction > 0 ? y <= yEnd : y >= yEnd;
      y += stepSize * direction
    ) {
      for (let i = 0; i < xCandidates.length; i++) {
        const index = charIndexAtPoint(xCandidates[i], y);
        if (index !== null) {
          return index;
        }
      }
    }
    return null;
  }

  function getStartCharIndex() {
    const step = Math.max(10, Math.round(pageHeight / 20));
    const left = contentLeft + 2;
    const right = contentLeft + pageWidth - 2;
    const middle = contentLeft + pageWidth * 0.5;
    const top = contentTop + 2;
    const bottom = contentTop + pageHeight - 2;
    const candidates = [left, middle, right];
    const found = findCharIndexInColumn(candidates, top, bottom, step);
    if (found !== null) {
      return found;
    }
    return charIndexAtPoint(middle, contentTop + pageHeight * 0.5);
  }

  function getEndCharIndex() {
    const step = Math.max(10, Math.round(pageHeight / 20));
    const left = contentLeft + 2;
    const right = contentLeft + pageWidth - 2;
    const middle = contentLeft + pageWidth * 0.5;
    const top = contentTop + 2;
    const bottom = contentTop + pageHeight - 2;
    const candidates = [right, middle, left];
    const found = findCharIndexInColumn(candidates, bottom, top, step);
    if (found !== null) {
      return found;
    }
    return charIndexAtPoint(middle, contentTop + pageHeight * 0.5);
  }

  function getVisibleText() {
    updateLayoutMetrics();
    const startRange = getRangeFromPoint(contentLeft + 2, contentTop + 2);
    const endRange = getRangeFromPoint(
      contentLeft + pageWidth - 2,
      contentTop + pageHeight - 2
    );
    const startPos = resolveRangePosition(startRange);
    const endPos = resolveRangePosition(endRange);
    if (!startPos || !endPos) {
      return null;
    }
    if (reader && (!reader.contains(startPos.node) || !reader.contains(endPos.node))) {
      return null;
    }
    const range = document.createRange();
    if (startPos.node === endPos.node) {
      const startOffset = Math.min(startPos.offset, endPos.offset);
      const endOffset = Math.max(startPos.offset, endPos.offset);
      range.setStart(startPos.node, startOffset);
      range.setEnd(endPos.node, endOffset);
    } else {
      const position = startPos.node.compareDocumentPosition(endPos.node);
      const startBeforeEnd = (position & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
      const endBeforeStart = (position & Node.DOCUMENT_POSITION_PRECEDING) !== 0;
      if (startBeforeEnd || !endBeforeStart) {
        range.setStart(startPos.node, startPos.offset);
        range.setEnd(endPos.node, endPos.offset);
      } else {
        range.setStart(endPos.node, endPos.offset);
        range.setEnd(startPos.node, startPos.offset);
      }
    }
    const text = normalizeWhitespace(range.toString());
    return text;
  }

  function getPageInfo(pageIndex) {
    updateLayoutMetrics();
    const scrollElement = getScrollContainer();
    const previousScroll = scrollElement ? scrollElement.scrollLeft : 0;
    const previousPage = currentPage;
    const previousStart = lastStartChar;
    const previousEnd = lastEndChar;
    const clamped = Math.min(Math.max(pageIndex, 0), pageCount - 1);
    if (scrollElement) {
      scrollElement.scrollLeft = Math.round(clamped * pageStride);
    }
    const startChar = getStartCharIndex();
    const endChar = getEndCharIndex();
    if (scrollElement) {
      scrollElement.scrollLeft = previousScroll;
    }
    currentPage = previousPage;
    lastStartChar = previousStart;
    lastEndChar = previousEnd;
    return JSON.stringify({
      pageIndex: clamped,
      startChar: startChar,
      endChar: endChar
    });
  }

  function setPage(pageIndex, notify) {
    updateLayoutMetrics();
    clearSelection();
    const clamped = Math.min(Math.max(pageIndex, 0), pageCount - 1);
    const scrollElement = getScrollContainer();
    currentPage = clamped;
    if (scrollElement) {
      scrollElement.scrollLeft = Math.round(clamped * pageStride);
    }
    const startCharValue = getStartCharIndex();
    const endCharValue = getEndCharIndex();
    const startChar = startCharValue === null ? lastStartChar : startCharValue;
    const endChar = endCharValue === null ? Math.max(startChar, lastEndChar) : endCharValue;
    if (startCharValue !== null) {
      lastStartChar = startCharValue;
    }
    if (endCharValue !== null) {
      lastEndChar = endCharValue;
    }
    if (notify) {
      postMessage({
        type: 'pageChanged',
        pageIndex: currentPage,
        pageCount: pageCount,
        totalChars: totalChars || 0,
        startChar: startChar,
        endChar: endChar
      });
    }
    return { startChar: startChar, endChar: endChar };
  }

  function getCharIndexForPage(pageIndex) {
    updateLayoutMetrics();
    const clamped = Math.min(Math.max(pageIndex, 0), pageCount - 1);
    const scrollElement = getScrollContainer();
    if (scrollElement) {
      scrollElement.scrollLeft = Math.round(clamped * pageStride);
    }
    return getStartCharIndex();
  }

  function findPageForChar(targetChar) {
    updateLayoutMetrics();
    let low = 0;
    let high = pageCount - 1;
    let best = 0;
    while (low <= high) {
      const mid = (low + high) >> 1;
      const startChar = getCharIndexForPage(mid);
      if (startChar === null) {
        best = mid;
        break;
      }
      if (startChar <= targetChar) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best;
  }

  function goToCharIndex(targetChar) {
    const page = findPageForChar(targetChar);
    setPage(page, true);
    return page;
  }

  function updateStyles(styles) {
    if (styles && typeof styles === 'object') {
      if (styles.fontSize) {
        document.documentElement.style.setProperty('--reader-font-size', styles.fontSize + 'px');
      }
      if (styles.lineHeight) {
        document.documentElement.style.setProperty('--reader-line-height', styles.lineHeight);
      }
      if (styles.textColor) {
        document.documentElement.style.setProperty('--reader-text-color', styles.textColor);
      }
      if (styles.backgroundColor) {
        document.documentElement.style.setProperty('--reader-bg-color', styles.backgroundColor);
      }
      if (typeof styles.paddingX === 'number') {
        document.documentElement.style.setProperty('--reader-padding-x', styles.paddingX + 'px');
      }
      if (typeof styles.paddingY === 'number') {
        document.documentElement.style.setProperty('--reader-padding-y', styles.paddingY + 'px');
      }
    }
    updateLayout();
  }

  function updateLayout() {
    updateLayoutMetrics();
    if (totalChars === null) {
      totalChars = computeCharCount(null, 0);
    }
    const startCharValue = getStartCharIndex();
    const targetChar = startCharValue === null ? 0 : startCharValue;
    const page = findPageForChar(targetChar);
    setPage(page, true);
  }

  function setActionLabel(label) {
    selectionButton.textContent = label || 'Translate';
  }

  function setActionEnabled(enabled) {
    actionEnabled = !!enabled;
    selectionButton.disabled = !actionEnabled;
  }

  function hideSelectionMenu() {
    selectionMenu.style.display = 'none';
  }

  function showSelectionMenu() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) {
      hideSelectionMenu();
      return;
    }
    const range = selection.getRangeAt(0);
    const rect = range.getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) {
      hideSelectionMenu();
      return;
    }
    selectionMenu.style.display = 'flex';
    const menuWidth = selectionMenu.offsetWidth;
    const menuHeight = selectionMenu.offsetHeight;
    const left = Math.min(
      Math.max(rect.left, selectionPadding),
      window.innerWidth - menuWidth - selectionPadding
    );
    const top = Math.max(rect.top - menuHeight - selectionPadding, selectionPadding);
    selectionMenu.style.transform = 'translate(' + left + 'px, ' + top + 'px)';
  }

  function getSelectionInfo() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) {
      return null;
    }
    const text = selection.toString().trim();
    if (!text) {
      return null;
    }
    const range = selection.getRangeAt(0);
    const rect = range.getBoundingClientRect();
    if (!rect) {
      return { text: text, rect: null };
    }
    return {
      text: text,
      rect: {
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
        width: rect.width,
        height: rect.height
      }
    };
  }

  function clearSelection() {
    const selection = window.getSelection();
    if (selection) {
      selection.removeAllRanges();
    }
    hideSelectionMenu();
    postMessage({ type: 'selectionChanged', hasSelection: false, text: '', rect: null });
  }

  function selectAll() {
    if (!reader) {
      return;
    }
    const selection = window.getSelection();
    if (!selection) {
      return;
    }
    const range = document.createRange();
    range.selectNodeContents(reader);
    selection.removeAllRanges();
    selection.addRange(range);
    handleSelectionChange();
  }

  function handleSelectionChange() {
    if (selectionTimer) {
      clearTimeout(selectionTimer);
    }
    selectionTimer = setTimeout(function() {
      const info = getSelectionInfo();
      if (!info) {
        hideSelectionMenu();
        postMessage({ type: 'selectionChanged', hasSelection: false, text: '', rect: null });
        return;
      }
      hideSelectionMenu();
      postMessage({
        type: 'selectionChanged',
        hasSelection: true,
        text: info.text,
        rect: info.rect
      });
    }, 80);
  }

  function determineTapAction(x, y) {
    const topThreshold = viewportHeight * 0.2;
    const bottomThreshold = viewportHeight * 0.8;
    const leftThreshold = viewportWidth * 0.33;
    const rightThreshold = viewportWidth * 0.67;

    if (y <= topThreshold) {
      return 'showMenu';
    }
    if (y >= bottomThreshold) {
      return 'showProgress';
    }
    if (x >= rightThreshold) {
      return 'nextPage';
    }
    if (x <= leftThreshold) {
      return 'previousPage';
    }
    return 'dismissOverlays';
  }

  function handleTap(x, y) {
    updateLayoutMetrics();
    const selection = window.getSelection();
    if (selection && selection.toString().trim().length > 0) {
      clearSelection();
      return;
    }
    const action = determineTapAction(x, y);
    if (action === 'nextPage') {
      setPage(currentPage + 1, true);
      return;
    }
    if (action === 'previousPage') {
      setPage(currentPage - 1, true);
      return;
    }
    postMessage({ type: 'tap', action: action });
  }

  function handleTouchStart(event) {
    if (event.target && event.target.closest) {
      if (event.target.closest('#selection-menu')) {
        return;
      }
    }
    if (!event.touches || event.touches.length === 0) {
      return;
    }
    const touch = event.touches[0];
    touchStart = {
      x: touch.clientX,
      y: touch.clientY,
      time: Date.now()
    };
  }

  function handleTouchEnd(event) {
    if (event.target && event.target.closest) {
      if (event.target.closest('#selection-menu')) {
        return;
      }
    }
    if (!touchStart) {
      return;
    }
    const touch = event.changedTouches && event.changedTouches.length > 0
      ? event.changedTouches[0]
      : null;
    if (!touch) {
      touchStart = null;
      return;
    }
    const dx = touch.clientX - touchStart.x;
    const dy = touch.clientY - touchStart.y;
    const dt = Date.now() - touchStart.time;
    const absDx = Math.abs(dx);
    const absDy = Math.abs(dy);
    touchStart = null;

    const selection = window.getSelection();
    if (selection && selection.toString().trim().length > 0) {
      if (absDx < 10 && absDy < 10 && dt < 300) {
        clearSelection();
      } else {
        handleSelectionChange();
      }
      return;
    }

    if (absDx > 50 && absDx > absDy && dt < 500) {
      if (dx < 0) {
        setPage(currentPage + 1, true);
      } else {
        setPage(currentPage - 1, true);
      }
      return;
    }
    if (absDx < 10 && absDy < 10 && dt < 300) {
      handleTap(touch.clientX, touch.clientY);
    }
    lastTouchTime = Date.now();
  }

  function handleTouchCancel() {
    touchStart = null;
  }

  function handleClick(event) {
    if (!event || !event.clientX || !event.clientY) {
      return;
    }
    if (Date.now() - lastTouchTime < 500) {
      return;
    }
    if (event.target && event.target.closest) {
      if (event.target.closest('#selection-menu')) {
        return;
      }
      const link = event.target.closest('a');
      if (link) {
        event.preventDefault();
      }
    }
    handleTap(event.clientX, event.clientY);
  }

  selectionButton.addEventListener('click', function(event) {
    event.preventDefault();
    const selection = window.getSelection();
    const text = selection ? selection.toString().trim() : '';
    if (!text || !actionEnabled) {
      return;
    }
    postMessage({ type: 'selectionAction', text: text });
    clearSelection();
  });

  if (selectionCopy) {
    selectionCopy.addEventListener('click', function(event) {
      event.preventDefault();
      const selection = window.getSelection();
      const text = selection ? selection.toString() : '';
      if (!text) {
        return;
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(function() {});
      } else {
        try {
          document.execCommand('copy');
        } catch (error) {}
      }
      clearSelection();
    });
  }

  if (selectionSelectAll) {
    selectionSelectAll.addEventListener('click', function(event) {
      event.preventDefault();
      selectAll();
    });
  }

  document.addEventListener('selectionchange', handleSelectionChange);
  const tapTarget = reader || document;
  tapTarget.addEventListener('touchstart', handleTouchStart, { passive: true });
  tapTarget.addEventListener('touchend', handleTouchEnd, { passive: true });
  tapTarget.addEventListener('touchcancel', handleTouchCancel, { passive: true });
  tapTarget.addEventListener('click', handleClick);
  window.addEventListener('resize', updateLayout);
  document.addEventListener('contextmenu', function(event) {
    const selection = window.getSelection();
    if (selection && selection.toString().trim().length > 0) {
      event.preventDefault();
    }
  });

  window.MemoReaderApi = {
    updateStyles: updateStyles,
    updateLayout: updateLayout,
    setPage: function(pageIndex, notify) {
      return setPage(pageIndex, notify !== false);
    },
    nextPage: function() {
      return setPage(currentPage + 1, true);
    },
    previousPage: function() {
      return setPage(currentPage - 1, true);
    },
    findPageForChar: findPageForChar,
    goToCharIndex: goToCharIndex,
    getPageCount: function() { return pageCount; },
    getCurrentPage: function() { return currentPage; },
    getVisibleText: getVisibleText,
    getPageInfo: getPageInfo,
    setActionLabel: setActionLabel,
    setActionEnabled: setActionEnabled,
    clearSelection: clearSelection,
    selectAll: selectAll
  };

  function init() {
    Promise.all([waitForFonts(), waitForImages()]).then(function() {
      updateLayoutMetrics();
      if (totalChars === null) {
        totalChars = computeCharCount(null, 0);
      }
      const info = setPage(currentPage, false);
      postMessage({
        type: 'ready',
        pageIndex: currentPage,
        pageCount: pageCount,
        totalChars: totalChars,
        startChar: info.startChar,
        endChar: info.endChar
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
''';

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

class _WebViewDocument {
  const _WebViewDocument({
    required this.html,
    required this.chapterCharOffsets,
    required this.totalCharacters,
    required this.fullText,
  });

  final String html;
  final List<_ChapterOffset> chapterCharOffsets;
  final int totalCharacters;
  final String fullText;
}

class _ChapterOffset {
  const _ChapterOffset({
    required this.chapterIndex,
    required this.startChar,
  });

  final int chapterIndex;
  final int startChar;
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

/// Small holder for a parsed selection action result.
/// Keeps both the raw response and the structured fields when available.
class _ParsedSelectionActionResult {
  const _ParsedSelectionActionResult({
    required this.originalFromResponse,
    this.pronunciation,
    this.translation,
  });

  final String? originalFromResponse;
  final String? pronunciation;
  final String? translation;
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

/// Dialog for asking questions about the book using RAG
class _RagQuestionDialog extends StatefulWidget {
  const _RagQuestionDialog({
    required this.bookId,
    required this.currentCharPosition,
    required this.ragQueryService,
    required this.summaryService,
    required this.l10n,
  });

  final String bookId;
  final int currentCharPosition;
  final RagQueryService ragQueryService;
  final EnhancedSummaryService? summaryService;
  final AppLocalizations l10n;

  @override
  State<_RagQuestionDialog> createState() => _RagQuestionDialogState();
}

class _RagQuestionDialogState extends State<_RagQuestionDialog> {
  final TextEditingController _questionController = TextEditingController();
  bool _onlyReadSoFar = true;
  bool _isProcessing = false;
  String? _answer;
  String? _error;
  bool _canSubmit = false;

  @override
  void initState() {
    super.initState();
    _questionController.addListener(_handleQuestionChanged);
    _handleQuestionChanged();
  }

  @override
  void dispose() {
    _questionController.removeListener(_handleQuestionChanged);
    _questionController.dispose();
    super.dispose();
  }

  void _handleQuestionChanged() {
    final hasText = _questionController.text.trim().isNotEmpty;
    if (hasText != _canSubmit && mounted) {
      setState(() {
        _canSubmit = hasText;
      });
    }
  }

  Future<void> _submitQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _answer = null;
      _error = null;
    });

    try {
      final summaryService = widget.summaryService;
      if (summaryService == null) {
        throw Exception('Summary service not available');
      }

      // EnhancedSummaryService wraps a SummaryService, get the underlying service
      final baseService = summaryService.baseService;
      
      // Get language from app locale
      final language = widget.l10n.localeName.split('_')[0]; // 'fr' or 'en'
      
      final result = await widget.ragQueryService.query(
        bookId: widget.bookId,
        question: question,
        onlyReadSoFar: _onlyReadSoFar,
        maxCharPosition: widget.currentCharPosition,
        summaryService: baseService,
        language: language,
      );

      if (mounted) {
        setState(() {
          _answer = result.answer;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('[RAG] Question error: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = widget.l10n;

    return AlertDialog(
      title: Text(l10n.ragAskQuestion),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _questionController,
                decoration: InputDecoration(
                  labelText: l10n.ragQuestionField,
                  hintText: l10n.ragQuestionField,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 4,
                enabled: !_isProcessing,
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: Text(
                  _onlyReadSoFar
                      ? l10n.ragAskReadSoFar
                      : l10n.ragAskWholeBook,
                ),
                value: _onlyReadSoFar,
                onChanged: _isProcessing
                    ? null
                    : (value) {
                        setState(() {
                          _onlyReadSoFar = value;
                        });
                      },
                contentPadding: EdgeInsets.zero,
              ),
              if (_isProcessing) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_answer != null) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.ragAnswerLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _answer!,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isProcessing
              ? null
              : () {
                  Navigator.of(context).pop();
                },
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _isProcessing || !_canSubmit
              ? null
              : _submitQuestion,
          child: Text(l10n.ragSubmitQuestion),
        ),
      ],
    );
  }
}

/// Dialog for showing the latest events summary
class _LatestEventsDialog extends StatefulWidget {
  const _LatestEventsDialog({
    required this.bookId,
    required this.currentCharPosition,
    required this.summaryService,
    required this.l10n,
  });

  final String bookId;
  final int currentCharPosition;
  final EnhancedSummaryService? summaryService;
  final AppLocalizations l10n;

  @override
  State<_LatestEventsDialog> createState() => _LatestEventsDialogState();
}

class _LatestEventsDialogState extends State<_LatestEventsDialog> {
  bool _autoShow = false;
  bool _isLoading = true;
  String? _summary;
  String? _error;

  final LatestEventsService _latestEventsService = LatestEventsService();
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    _loadPreference();
    _generateSummary();
  }

  Future<void> _loadPreference() async {
    final autoShow = await _settingsService.getAutoShowLatestEvents(widget.bookId);
    if (mounted) {
      setState(() {
        _autoShow = autoShow;
      });
    }
  }

  Future<void> _generateSummary() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _summary = null;
    });

    try {
      final summaryService = widget.summaryService;
      if (summaryService == null) {
        throw Exception('Summary service not available');
      }

      // EnhancedSummaryService wraps a SummaryService, get the underlying service
      final baseService = summaryService.baseService;

      // Get language from app locale (use localeName from l10n, which is already available)
      // localeName is like 'fr' or 'en', extract just the language code
      final language = widget.l10n.localeName.split('_')[0]; // 'fr' or 'en'

      final summary = await _latestEventsService.generateLatestEventsSummary(
        bookId: widget.bookId,
        currentCharPosition: widget.currentCharPosition,
        summaryService: baseService,
        language: language,
        numChunks: 10,
      );

      if (mounted) {
        setState(() {
          _summary = summary;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[LatestEvents] Error generating summary: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _toggleAutoShow(bool value) async {
    setState(() {
      _autoShow = value;
    });
    await _settingsService.setAutoShowLatestEvents(widget.bookId, value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = widget.l10n;

    return AlertDialog(
      title: Text(l10n.ragLatestEventsTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Auto-show toggle at the top
              SwitchListTile(
                title: Text(l10n.ragAutoShowLatestEvents),
                subtitle: Text(
                  l10n.ragAutoShowDescription,
                  style: theme.textTheme.bodySmall,
                ),
                value: _autoShow,
                onChanged: _toggleAutoShow,
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(),
              const SizedBox(height: 16),
              
              // Loading state
              if (_isLoading) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    l10n.ragLatestEventsGenerating,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
              
              // Error state
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              
              // Summary display
              if (_summary != null) ...[
                Text(
                  l10n.ragLatestEventsPrompt,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _summary!,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(l10n.ok),
        ),
      ],
    );
  }
}

