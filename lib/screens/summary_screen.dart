import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../services/settings_service.dart';
import '../services/enhanced_summary_service.dart';
import '../services/background_summary_service.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';
import 'summary_debug_screen.dart';

enum SummaryType {
  fromBeginning,
  sinceLastTime,
  characters,
}

class SummaryScreen extends StatefulWidget {
  final Book book;
  final ReadingProgress progress;
  final EnhancedSummaryService enhancedSummaryService;
  final String engineFullText;
  final SummaryType summaryType;

  const SummaryScreen({
    super.key,
    required this.book,
    required this.progress,
    required this.enhancedSummaryService,
    required this.summaryType,
    required this.engineFullText,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final SettingsService _settingsService = SettingsService();
  double _fontSize = 18.0;
  bool _isLoading = true;
  String _summary = '';
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    // Defer _loadSummary to after the first frame so context is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadSummary();
      }
    });
    _loadFontSize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload font size when screen becomes visible
    _loadFontSize();
  }

  Future<void> _loadSummary() async {
    final l10n = AppLocalizations.of(context)!;
    
    debugPrint('[SummaryScreen] _loadSummary called for summaryType: ${widget.summaryType}');
    debugPrint('[SummaryScreen] Book ID: ${widget.book.id}, currentCharacterIndex: ${widget.progress.currentCharacterIndex}');

    setState(() {
      _isLoading = true;
      _statusMessage = l10n.summaryStatusPreparing;
    });

    try {
      // Check if background generation is in progress and wait for it
      final backgroundService = BackgroundSummaryService();
      if (backgroundService.isGenerationInProgress(widget.book.id)) {
        debugPrint('[SummaryScreen] Background generation in progress, waiting...');
        // Wait for background generation to complete (with timeout)
        await Future.any([
          backgroundService.waitForGeneration(widget.book.id),
          Future.delayed(const Duration(seconds: 30)), // Timeout after 30 seconds
        ]);
        debugPrint('[SummaryScreen] Background generation wait completed');
      }

      // Get app language
      final appLocale = Localizations.localeOf(context);
      final languageCode = appLocale.languageCode;
      final summaryType = widget.summaryType;

      debugPrint('[SummaryScreen] Language code: $languageCode, calling summary service...');
      
      // Track if we get a cache hit
      bool cacheHitDetected = false;
      final cacheHitCallback = () {
        cacheHitDetected = true;
        if (mounted) {
          _updateStatusMessage(l10n.summaryFoundInCache);
        }
      };

      _updateStatusMessage(
        l10n.summaryStatusCalling(widget.enhancedSummaryService.serviceName),
      );

      String summary;
      if (summaryType == SummaryType.sinceLastTime) {
        debugPrint('[SummaryScreen] Calling getSummarySinceLastTime...');
        summary = await widget.enhancedSummaryService.getSummarySinceLastTime(
          widget.book,
          widget.progress,
          languageCode,
          preparedEngineText: widget.engineFullText,
          onCacheHit: cacheHitCallback,
        );
        debugPrint('[SummaryScreen] getSummarySinceLastTime completed, summary length: ${summary.length}');
      } else if (summaryType == SummaryType.characters) {
        debugPrint('[SummaryScreen] Calling getCharactersSummary...');
        summary = await widget.enhancedSummaryService.getCharactersSummary(
          widget.book,
          widget.progress,
          languageCode,
          preparedEngineText: widget.engineFullText,
          onCacheHit: cacheHitCallback,
        );
        debugPrint('[SummaryScreen] getCharactersSummary completed, summary length: ${summary.length}');
      } else {
        debugPrint('[SummaryScreen] Calling getSummaryUpToPosition...');
        summary = await widget.enhancedSummaryService.getSummaryUpToPosition(
          widget.book,
          widget.progress,
          languageCode,
          preparedEngineText: widget.engineFullText,
          onCacheHit: cacheHitCallback,
        );
        debugPrint('[SummaryScreen] getSummaryUpToPosition completed, summary length: ${summary.length}');
      }

      // Update last summary view position
      debugPrint('[SummaryScreen] Updating last summary view position...');
      final characterIndex = widget.progress.currentCharacterIndex ?? 0;
      final chunkIndex =
          EnhancedSummaryService.computeChunkIndexForCharacterStatic(characterIndex);
      await widget.enhancedSummaryService.updateLastSummaryView(
        widget.book.id,
        chunkIndex,
      );
      debugPrint('[SummaryScreen] Last summary view position updated');

      if (mounted) {
        debugPrint('[SummaryScreen] Setting state with summary (length: ${summary.length})');
        setState(() {
          _summary = summary;
          _isLoading = false;
          _statusMessage = null;
        });
        debugPrint('[SummaryScreen] State updated, loading complete');
      }
    } catch (e, stackTrace) {
      debugPrint('[SummaryScreen] Error in _loadSummary: $e');
      debugPrint('[SummaryScreen] Stack trace: $stackTrace');
      if (mounted) {
        final errorMessage = e.toString();
        String userFriendlyMessage;

        // Provide user-friendly error messages
        if (errorMessage.contains('timeout')) {
          userFriendlyMessage = 'Summary generation timed out. Please check your internet connection and try again.';
        } else if (errorMessage.contains('not available') || errorMessage.contains('not configured')) {
          userFriendlyMessage = 'Summary service is not available. Please check your settings and ensure an API key is configured.';
        } else {
          userFriendlyMessage = 'Error generating summary: $errorMessage\n\nIf this persists, please check your API key configuration in settings.';
        }

        debugPrint('[SummaryScreen] Setting error state: $userFriendlyMessage');
        setState(() {
          _summary = userFriendlyMessage;
          _isLoading = false;
          _statusMessage = null;
        });
      }
    }
  }

  void _updateStatusMessage(String message) {
    if (!mounted || !_isLoading) return;
    setState(() {
      _statusMessage = message;
    });
  }

  Future<void> _loadFontSize() async {
    final fontSize = await _settingsService.getFontSize();
    if (mounted) {
      setState(() {
        _fontSize = fontSize;
      });
    }
  }

  Future<void> _resetCurrentSummary() async {
    if (_isLoading) return;
    final l10n = AppLocalizations.of(context)!;

    try {
      // Clear the cache for the specific summary type
      switch (widget.summaryType) {
        case SummaryType.fromBeginning:
          await widget.enhancedSummaryService
              .resetGeneralSummary(widget.book.id);
          break;
        case SummaryType.sinceLastTime:
          await widget.enhancedSummaryService
              .resetSinceLastTimeSummary(widget.book.id);
          break;
        case SummaryType.characters:
          await widget.enhancedSummaryService
              .resetCharactersSummary(widget.book.id);
          break;
      }

      // Close the summary screen and show toast message
      if (mounted) {
        // Get the messenger before popping - it will use the root ScaffoldMessenger
        final messenger = ScaffoldMessenger.of(context);
        
        // Pop the summary screen
        Navigator.of(context).pop();
        
        // Show toast message after the screen is popped
        // Using post-frame callback ensures the reader screen is active
        WidgetsBinding.instance.addPostFrameCallback((_) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(l10n.summaryDeleted),
              duration: const Duration(seconds: 2),
            ),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.resetSummariesError)),
      );
    }
  }

  String _titleForSummaryType(AppLocalizations l10n) {
    switch (widget.summaryType) {
      case SummaryType.sinceLastTime:
        return l10n.summarySinceLastTime;
      case SummaryType.characters:
        return l10n.summaryCharacters;
      case SummaryType.fromBeginning:
      default:
        return l10n.summaryFromBeginning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F0), // Light beige/cream background
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l10n.generatingSummary),
              if (_statusMessage?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(_statusMessage!),
              ],
            ],
          ),
        ),
      );
    }

    if (_summary.isEmpty && !_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F0),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(l10n),
              Expanded(
                child: Center(
                  child: Text(l10n.noContentAvailable),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F0),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(l10n),
            // Scrollable summary content with scrollbar
            Expanded(
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: MarkdownBody(
                    data: _summary,
                    styleSheet: MarkdownStyleSheet(
                      p: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontSize: _fontSize,
                        height: 1.6,
                      ),
                      h1: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        fontSize: _fontSize * 1.5,
                        fontWeight: FontWeight.bold,
                      ),
                      h2: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontSize: _fontSize * 1.3,
                        fontWeight: FontWeight.bold,
                      ),
                      h3: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontSize: _fontSize * 1.2,
                        fontWeight: FontWeight.bold,
                      ),
                      h4: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: _fontSize * 1.1,
                        fontWeight: FontWeight.bold,
                      ),
                      h5: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize: _fontSize * 1.05,
                        fontWeight: FontWeight.bold,
                      ),
                      h6: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontSize: _fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                      strong: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontSize: _fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                      em: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontSize: _fontSize,
                        fontStyle: FontStyle.italic,
                      ),
                      listIndent: 24,
                      listBullet: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontSize: _fontSize,
                      ),
                      code: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontSize: _fontSize * 0.9,
                        fontFamily: 'monospace',
                        backgroundColor: Colors.grey[200],
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      blockquote: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontSize: _fontSize,
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[700],
                      ),
                      blockquoteDecoration: BoxDecoration(
                        color: Colors.grey[100],
                        border: Border(
                          left: BorderSide(
                            color: Colors.grey[400]!,
                            width: 4,
                          ),
                        ),
                      ),
                      textAlign: WrapAlignment.start,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    final title = _titleForSummaryType(l10n);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ) ??
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: l10n.summaryReset,
            onPressed: _isLoading ? null : _resetCurrentSummary,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Voir les résumés intermédiaires (Debug)',
            onPressed: _isLoading
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SummaryDebugScreen(
                          book: widget.book,
                          enhancedSummaryService: widget.enhancedSummaryService,
                        ),
                      ),
                    );
                  },
            icon: const Icon(Icons.bug_report),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

