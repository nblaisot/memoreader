import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:epubx/epubx.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';
import '../services/book_loader_service.dart';
import '../services/settings_service.dart';
import '../services/summary_service.dart';
import '../services/summary_database_service.dart';
import '../services/important_words_service.dart';
import 'summary_screen.dart';
import 'important_words_screen.dart';
import '../widgets/reader_helpers.dart';

/// Main screen for reading EPUB books
/// 
/// This screen provides:
/// - Page-by-page reading with tap navigation (left/right)
/// - Chapter navigation
/// - Font size adjustment
/// - Reading progress tracking
/// - Access to summaries and important words
/// - Menu overlay for additional options
class ReaderScreen extends StatefulWidget {
  final Book book;

  const ReaderScreen({super.key, required this.book});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  final BookService _bookService = BookService();
  final SettingsService _settingsService = SettingsService();
  final SummaryService _summaryService = SummaryService();
  final SummaryDatabaseService _summaryDbService = SummaryDatabaseService();
  final ImportantWordsService _importantWordsService = ImportantWordsService();
  List<Chapter> _chapters = [];
  int _currentChapterIndex = 0;
  int _currentPageInChapter = 0;
  bool _isLoading = true;
  bool _showMenu = false;
  bool _showProgress = false; // Control progress bar visibility
  List<String> _pages = []; // Pages for current chapter
  Map<int, int> _chapterPageCounts = {}; // Track page counts per chapter
  String? _errorMessage;
  final PageController _pageController = PageController();
  bool _isProcessingPageChange = false;
  double _fontSize = 18.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFontSize();
    _loadBook();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload font size when screen becomes visible (e.g., returning from settings)
    _loadFontSize();
  }

  Future<void> _loadFontSize() async {
    final fontSize = await _settingsService.getFontSize();
    if (mounted && _fontSize != fontSize) {
      setState(() {
        _fontSize = fontSize;
      });
    }
  }

  @override
  void dispose() {
    // Save reading stop position when leaving reader screen
    _saveReadingStop();
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  /// Toggle progress bar visibility when user taps bottom of screen
  void _toggleProgress() {
    setState(() {
      _showProgress = !_showProgress;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Save reading stop when app goes to background or is terminated
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveReadingStop();
    }
  }

  Future<void> _saveReadingStop() async {
    try {
      // Save where user stopped reading (for reading session tracking)
      await _summaryService.updateLastReadingStop(
        widget.book.id,
        _currentChapterIndex,
      );
    } catch (e) {
      debugPrint('Error saving reading stop position: $e');
      // Don't show error - this is best effort
    }
  }

  Future<void> _checkNewReadingSession(int previousChapterIndex) async {
    try {
      // When user opens reader, check if they've progressed past last reading stop
      // This indicates they've started a new reading session
      final cache = await _summaryDbService.getSummaryCache(widget.book.id);
      final lastReadingStop = cache?.lastReadingStopChunkIndex;
      
      // If user is at a position beyond where they last stopped, they're in a new session
      // The reading stop will be updated when they leave (dispose)
      if (lastReadingStop != null && _currentChapterIndex > lastReadingStop) {
        // New session started - the "since last time" will correctly show content from 
        // lastReadingStop to currentChunkIndex when summary is generated
      }
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _checkAndSaveReadingSessionStart() async {
    try {
      // When user navigates forward, check if they've entered a new session
      // This helps track session boundaries during reading
      final cache = await _summaryDbService.getSummaryCache(widget.book.id);
      final lastReadingStop = cache?.lastReadingStopChunkIndex;
      
      if (lastReadingStop != null && _currentChapterIndex > lastReadingStop) {
        // User is reading new content beyond last stop - new session
        // Stop position will be saved when they leave
      }
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _loadBook() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Validate file path
      if (widget.book.filePath.isEmpty) {
        throw Exception('Book file path is empty');
      }

      // Load EPUB
      _epubBook = await _bookService.loadEpubBook(widget.book.filePath);
      
      if (_epubBook == null) {
        throw Exception('Failed to load EPUB file');
      }
      
      // Parse chapters using helper
      _chapters = ReaderHelpers.parseChapters(_epubBook!);
      
      if (_chapters.isEmpty) {
        throw Exception('No chapters found in this book');
      }
      
      // Load reading progress
      final progress = await _bookService.getReadingProgress(widget.book.id);
      if (progress != null) {
        // Validate progress
        if (progress.currentChapterIndex >= 0 && 
            progress.currentChapterIndex < _chapters.length) {
          _currentChapterIndex = progress.currentChapterIndex;
          _currentPageInChapter = progress.currentPageInChapter;
        }
      }
      
      // Load current chapter pages
      await _loadCurrentChapterPages();
      
      setState(() {
        _isLoading = false;
      });

    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorLoadingBook(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: l10n.retry,
              textColor: Colors.white,
              onPressed: _loadBook,
            ),
          ),
        );
      }
    }
  }


  Future<void> _loadCurrentChapterPages() async {
    if (_chapters.isEmpty) {
      setState(() {
        _pages = [];
        _currentPageInChapter = 0;
      });
      return;
    }
    
    try {
      if (_currentChapterIndex < 0 || _currentChapterIndex >= _chapters.length) {
        _currentChapterIndex = 0;
      }
      
      final chapter = _chapters[_currentChapterIndex];
      // Split chapter into pages using helper with current font size
      final pages = await ReaderHelpers.splitIntoPages(
        context,
        chapter.htmlContent,
        fontSize: _fontSize,
        lineHeight: 1.6,
      );
      
      setState(() {
        _pages = pages.isNotEmpty ? pages : [chapter.htmlContent];
        _chapterPageCounts[_currentChapterIndex] = _pages.length;
        if (_currentPageInChapter >= _pages.length) {
          _currentPageInChapter = _pages.length - 1;
        }
        if (_currentPageInChapter < 0) {
          _currentPageInChapter = 0;
        }
      });
      
      await _saveProgress();
    } catch (e) {
      debugPrint('Error loading pages: $e');
      setState(() {
        _pages = _chapters[_currentChapterIndex].htmlContent.isNotEmpty
            ? [_chapters[_currentChapterIndex].htmlContent]
            : ['<p>Error loading chapter content.</p>'];
        _chapterPageCounts[_currentChapterIndex] = _pages.length;
      });
    }
  }

  /// Calculate overall reading progress
  /// 
  /// Returns a value between 0.0 and 1.0 representing how much of the book
  /// has been read based on chapters and pages within chapters.
  double _calculateOverallProgress() {
    if (_chapters.isEmpty || _pages.isEmpty) return 0.0;

    return ReaderHelpers.calculateOverallProgress(
      currentChapterIndex: _currentChapterIndex,
      currentPageInChapter: _currentPageInChapter,
      totalChapters: _chapters.length,
      pagesInCurrentChapter: _pages.length,
    );
  }

  Future<void> _saveProgress() async {
    try {
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentChapterIndex: _currentChapterIndex,
        currentPageInChapter: _currentPageInChapter,
        lastRead: DateTime.now(),
      );
      await _bookService.saveReadingProgress(progress);
    } catch (e) {
      debugPrint('Error saving progress: $e');
      // Don't show error to user - progress saving is best effort
    }
  }

  void _nextPage() {
    if (_isProcessingPageChange) return;
    
    setState(() {
      _isProcessingPageChange = true;
    });

    try {
      if (_currentPageInChapter < _pages.length - 1) {
        setState(() {
          _currentPageInChapter++;
        });
        _saveProgress();
        _checkAndSaveReadingSessionStart();
      } else if (_currentChapterIndex < _chapters.length - 1) {
        _goToChapter(_currentChapterIndex + 1);
      } else {
        // Last page of last chapter
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.endOfBookReached),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error navigating to next page: $e');
    } finally {
      setState(() {
        _isProcessingPageChange = false;
      });
    }
  }

  void _previousPage() {
    if (_isProcessingPageChange) return;
    
    setState(() {
      _isProcessingPageChange = true;
    });

    try {
      if (_currentPageInChapter > 0) {
        setState(() {
          _currentPageInChapter--;
        });
        _saveProgress();
      } else if (_currentChapterIndex > 0) {
        _goToChapter(_currentChapterIndex - 1);
        setState(() {
          _currentPageInChapter = _pages.length - 1;
        });
        _saveProgress();
      } else {
        // First page of first chapter
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.beginningOfBook),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error navigating to previous page: $e');
    } finally {
      setState(() {
        _isProcessingPageChange = false;
      });
    }
  }

  Future<void> _goToChapter(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.invalidChapterIndex),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      setState(() {
        _currentChapterIndex = chapterIndex;
        _currentPageInChapter = 0;
        _isLoading = true;
      });
      
      await _loadCurrentChapterPages();
      
      setState(() {
        _isLoading = false;
        _showMenu = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorLoadingChapter(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  void _showChapterList() {
    final l10n = AppLocalizations.of(context)!;
    if (_chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.noChaptersAvailable)),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              l10n.chapters,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _chapters.length,
                itemBuilder: (context, index) {
                  final chapter = _chapters[index];
                  final isCurrent = index == _currentChapterIndex;
                  return ListTile(
                    title: Text(
                      chapter.title,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(l10n.chapter(index + 1)),
                    selected: isCurrent,
                    selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
                    leading: isCurrent
                        ? Icon(Icons.bookmark, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      Navigator.pop(context);
                      _goToChapter(index);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSummaryDialog() async {
    try {
      // Get current reading progress
      final progress = ReadingProgress(
        bookId: widget.book.id,
        currentChapterIndex: _currentChapterIndex,
        currentPageInChapter: _currentPageInChapter,
        lastRead: DateTime.now(),
      );

      // Navigate to full-screen summary screen (it handles loading internally)
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SummaryScreen(
              book: widget.book,
              progress: progress,
              summaryService: _summaryService,
            ),
          ),
        );
      }
    } catch (e) {
      // Show error
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorGeneratingSummary(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showImportantWordsDialog() async {
    try {
      // Navigate to full-screen important words screen (it handles loading internally)
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ImportantWordsScreen(
              book: widget.book,
              importantWordsService: _importantWordsService,
            ),
          ),
        );
      }
    } catch (e) {
      // Show error
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorLoadingImportantWords(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showGoToPageDialog() {
    final l10n = AppLocalizations.of(context)!;
    if (_pages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.noPagesAvailable)),
      );
      return;
    }

    final controller = TextEditingController(
      text: (_currentPageInChapter + 1).toString(),
    );
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.goToPage),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: l10n.enterPageNumber(_pages.length),
            labelText: l10n.page,
            helperText: _pages.length == 1 
                ? l10n.thisChapterHasPages(_pages.length)
                : l10n.thisChapterHasPages_plural(_pages.length),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              final pageNum = int.tryParse(controller.text);
              if (pageNum != null && pageNum >= 1 && pageNum <= _pages.length) {
                setState(() {
                  _currentPageInChapter = pageNum - 1;
                });
                _saveProgress();
                Navigator.pop(context);
                setState(() {
                  _showMenu = false;
                });
              } else {
                final l10n = AppLocalizations.of(context)!;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.invalidPageNumber(_pages.length)),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: Text(l10n.go),
          ),
        ],
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_isLoading && _errorMessage == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                l10n.loadingBook(widget.book.title),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.book.title),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                const SizedBox(height: 16),
                Text(
                  l10n.errorLoadingBookTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red[600]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _loadBook,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_chapters.isEmpty || _pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.title)),
        body: Center(
          child: Text(l10n.noContentAvailable),
        ),
      );
    }

    // Calculate height of 5 lines of text (font size 18, line height 1.6)
    final lineHeight = 18.0 * 1.6;
    final fiveLinesHeight = lineHeight * 5;
    // Menu clickable area height (top margin 10px + first 5 lines)
    final clickableMenuHeight = 10.0 + fiveLinesHeight;
    
    return Scaffold(
      body: Stack(
        children: [
          // Reading area
          GestureDetector(
            onTapDown: (details) {
              final screenWidth = MediaQuery.of(context).size.width;
              final screenHeight = MediaQuery.of(context).size.height;
              final tapX = details.globalPosition.dx;
              final tapY = details.globalPosition.dy;
              
              // Close menu if clicking outside (tap handling for menu is done by overlay)
              if (_showMenu) {
                setState(() {
                  _showMenu = false;
                });
                return;
              }

              // Check if tap is in bottom 10% of screen (progress bar area)
              final isBottomTap = tapY > screenHeight * 0.9;
              if (isBottomTap) {
                _toggleProgress();
                return;
              }

              // Left half for previous page
              if (tapX < screenWidth / 2) {
                _previousPage();
              } else {
                // Right half for next page
                _nextPage();
              }
            },
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SafeArea(
                child: Column(
                  children: [
                    // Page content with 10px margins at top and bottom (like a book)
                    // Using ClipRect to prevent overflow and ensure content fits
                    Expanded(
                      child: ClipRect(
                        child: Container(
                          padding: const EdgeInsets.only(
                            top: 10.0, // 10px top margin
                            bottom: 10.0, // 10px bottom margin
                          ),
                          child: HtmlWidget(
                            _pages[_currentPageInChapter],
                            textStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontSize: _fontSize,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Footer with progress bar and page info (toggleable - click to hide)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _showProgress
                          ? GestureDetector(
                              onTap: _toggleProgress, // Click footer to hide it
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).scaffoldBackgroundColor,
                                  border: Border(
                                    top: BorderSide(
                                      color: Colors.grey[300]!,
                                      width: 1,
                                    ),
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Progress bar
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(2),
                                            child: LinearProgressIndicator(
                                              value: _calculateOverallProgress(),
                                              minHeight: 4,
                                              backgroundColor: Colors.grey[200],
                                              valueColor: AlwaysStoppedAnimation<Color>(
                                                Theme.of(context).colorScheme.primary,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${(_calculateOverallProgress() * 100).toStringAsFixed(0)}%',
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.grey[700],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    // Chapter and page info
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          l10n.chapterInfo(_currentChapterIndex + 1, _chapters.length),
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            fontSize: 11,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        Text(
                                          l10n.pageInfo(_currentPageInChapter + 1, _pages.length),
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            fontSize: 11,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Invisible clickable overlay for menu (top padding + first 5 lines)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: GestureDetector(
                onTapDown: (_) {
                  _toggleMenu();
                },
                child: Container(
                  height: clickableMenuHeight,
                  color: Colors.transparent, // Invisible but clickable
                ),
              ),
            ),
          ),
          // Menu overlay (dropdown)
          if (_showMenu)
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showMenu = false;
                  });
                },
                child: Stack(
                  children: [
                    // Semi-transparent backdrop
                    Container(
                      color: Colors.black54,
                    ),
                    // Dropdown menu
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        bottom: false,
                        child: GestureDetector(
                          onTap: () {
                            // Prevent closing menu when tapping on menu itself
                          },
                          child: Container(
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(20),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Text size slider as first entry
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0,
                                    vertical: 8.0,
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.text_fields),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Text(
                                              l10n.textSize,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                            ),
                                          ),
                                          Text(
                                            _fontSize.toStringAsFixed(0),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                          ),
                                        ],
                                      ),
                                      Slider(
                                        value: _fontSize,
                                        min: _settingsService.minFontSize,
                                        max: _settingsService.maxFontSize,
                                        divisions: 20,
                                        onChanged: (value) async {
                                          // Save current page index and old page count to maintain position
                                          final previousPageIndex = _currentPageInChapter;
                                          final oldPageCount = _pages.length;
                                          
                                          setState(() {
                                            _fontSize = value;
                                          });
                                          await _settingsService.saveFontSize(value);
                                          
                                          // Recalculate pages with new font size
                                          await _loadCurrentChapterPages();
                                          
                                          // Try to maintain approximate position after recalculation
                                          if (mounted && _pages.isNotEmpty && oldPageCount > 0) {
                                            // Adjust page index proportionally based on old vs new page count
                                            final progressRatio = (previousPageIndex + 1) / oldPageCount;
                                            final newPageIndex = (progressRatio * _pages.length - 1)
                                                .round()
                                                .clamp(0, _pages.length - 1);
                                            setState(() {
                                              _currentPageInChapter = newPageIndex;
                                            });
                                            await _saveProgress();
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(),
                                ListTile(
                                  leading: const Icon(Icons.summarize),
                                  title: Text(l10n.summary),
                                  onTap: () {
                                    setState(() {
                                      _showMenu = false;
                                    });
                                    _showSummaryDialog();
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.text_fields),
                                  title: Text(l10n.importantWords),
                                  onTap: () {
                                    setState(() {
                                      _showMenu = false;
                                    });
                                    _showImportantWordsDialog();
                                  },
                                ),
                                const Divider(),
                                ListTile(
                                  leading: const Icon(Icons.list),
                                  title: Text(l10n.chapters),
                                  onTap: () {
                                    setState(() {
                                      _showMenu = false;
                                    });
                                    _showChapterList();
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.pageview),
                                  title: Text(l10n.goToPage),
                                  onTap: () {
                                    setState(() {
                                      _showMenu = false;
                                    });
                                    _showGoToPageDialog();
                                  },
                                ),
                                const Divider(),
                                ListTile(
                                  leading: const Icon(Icons.arrow_back),
                                  title: Text(l10n.backToLibrary),
                                  onTap: () {
                                    Navigator.pop(context);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
