import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:epubx/epubx.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../services/book_service.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;

  const ReaderScreen({super.key, required this.book});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final BookService _bookService = BookService();
  EpubBook? _epubBook;
  List<Chapter> _chapters = [];
  int _currentChapterIndex = 0;
  int _currentPageInChapter = 0;
  bool _isLoading = true;
  bool _showMenu = false;
  List<String> _pages = []; // Pages for current chapter
  Map<int, int> _chapterPageCounts = {}; // Track page counts per chapter
  String? _errorMessage;
  final PageController _pageController = PageController();
  bool _isProcessingPageChange = false;

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
      
      // Parse chapters
      _chapters = _parseChapters(_epubBook!);
      
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

  List<Chapter> _parseChapters(EpubBook epubBook) {
    final chapters = <Chapter>[];
    
    try {
      final epubChapters = epubBook.Chapters;
      if (epubChapters == null || epubChapters.isEmpty) {
        return chapters;
      }
      
      for (int i = 0; i < epubChapters.length; i++) {
        try {
          final epubChapter = epubChapters[i];
          final title = epubChapter.Title?.isNotEmpty == true
              ? epubChapter.Title!
              : 'Chapter ${i + 1}';
          final htmlContent = epubChapter.HtmlContent ?? '';
          
          if (htmlContent.isNotEmpty) {
            chapters.add(Chapter(
              index: i,
              title: title,
              htmlContent: htmlContent,
            ));
          }
        } catch (e) {
          // Skip corrupted chapters
          debugPrint('Error parsing chapter $i: $e');
        }
      }
    } catch (e) {
      debugPrint('Error parsing chapters: $e');
    }
    
    return chapters.isEmpty ? [] : chapters;
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
      // Improved pagination based on screen size
      final pages = await _splitIntoPages(chapter.htmlContent);
      
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

  double _calculateOverallProgress() {
    if (_chapters.isEmpty || _pages.isEmpty) return 0.0;
    
    // Calculate progress based on chapters and pages
    // Approximate: each chapter contributes equally, and within a chapter progress is based on pages
    final chaptersRead = _currentChapterIndex.toDouble();
    final currentChapterProgress = _pages.isNotEmpty
        ? (_currentPageInChapter + 1) / _pages.length
        : 0.0;
    
    final totalChapters = _chapters.length.toDouble();
    final overallProgress = (chaptersRead + currentChapterProgress) / totalChapters;
    
    return overallProgress.clamp(0.0, 1.0);
  }

  Future<List<String>> _splitIntoPages(String htmlContent) async {
    if (htmlContent.isEmpty) {
      return ['<p>No content available.</p>'];
    }

    try {
      // Get screen dimensions for better pagination
      final mediaQuery = MediaQuery.of(context);
      final screenHeight = mediaQuery.size.height - 
                          mediaQuery.padding.top - 
                          mediaQuery.padding.bottom - 
                          200; // Account for padding and footer
      final screenWidth = mediaQuery.size.width - 32; // Account for padding

      // Estimate characters per page based on screen size
      // Rough estimate: ~50 characters per line, ~30 lines per page
      final estimatedCharsPerPage = ((screenWidth / 10) * (screenHeight / 20)).round();
      final charsPerPage = estimatedCharsPerPage > 500 ? estimatedCharsPerPage : 1500;

      // Split HTML by paragraphs while preserving structure
      final pages = <String>[];
      String currentPage = '';
      
      // Split by paragraphs
      final paragraphRegex = RegExp(r'<p[^>]*>.*?</p>', dotAll: true);
      final divRegex = RegExp(r'<div[^>]*>.*?</div>', dotAll: true);
      
      // Extract all content blocks
      final allMatches = <String>[];
      
      // Find all paragraphs
      paragraphRegex.allMatches(htmlContent).forEach((match) {
        allMatches.add(match.group(0)!);
      });
      
      // Find all divs that aren't already captured
      divRegex.allMatches(htmlContent).forEach((match) {
        final divContent = match.group(0)!;
        if (!allMatches.any((p) => p.contains(divContent))) {
          allMatches.add(divContent);
        }
      });
      
      // If no structured content, split by approximate page size
      if (allMatches.isEmpty) {
        for (int i = 0; i < htmlContent.length; i += charsPerPage) {
          final end = (i + charsPerPage < htmlContent.length) 
              ? i + charsPerPage 
              : htmlContent.length;
          pages.add(htmlContent.substring(i, end));
        }
        return pages.isEmpty ? [htmlContent] : pages;
      }
      
      // Build pages from content blocks
      for (final block in allMatches) {
        final blockLength = block.length;
        
        if (currentPage.length + blockLength > charsPerPage && currentPage.isNotEmpty) {
          pages.add(currentPage);
          currentPage = block;
        } else {
          currentPage += block;
        }
      }
      
      if (currentPage.isNotEmpty) {
        pages.add(currentPage);
      }
      
      return pages.isEmpty ? [htmlContent] : pages;
    } catch (e) {
      debugPrint('Error splitting pages: $e');
      return [htmlContent];
    }
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

  void _showSummaryDialog() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.summary),
        content: Text(l10n.summaryFeatureComingSoon),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.ok),
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

    return Scaffold(
      body: Stack(
        children: [
          // Reading area
          GestureDetector(
            onTapDown: (details) {
              final screenWidth = MediaQuery.of(context).size.width;
              final tapX = details.globalPosition.dx;
              final tapY = details.globalPosition.dy;
              
              // Top area for menu (first 80px)
              if (tapY < 80) {
                _toggleMenu();
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SafeArea(
                child: Column(
                  children: [
                    // Header with book info
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: _showMenu ? 60 : 0,
                      child: _showMenu
                          ? Container(
                              color: Theme.of(context).colorScheme.surface,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.book.title,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: _toggleMenu,
                                  ),
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    // Page content
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: HtmlWidget(
                          _pages[_currentPageInChapter],
                          textStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontSize: 18,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ),
                    // Footer with progress bar and page info
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
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
                  ],
                ),
              ),
            ),
          ),
          // Menu overlay
          if (_showMenu)
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleMenu,
                child: Container(
                  color: Colors.black54,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(20),
                          ),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
              ),
            ),
        ],
      ),
    );
  }
}
