import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../services/settings_service.dart';
import '../services/enhanced_summary_service.dart';
import '../services/background_summary_service.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';

enum SummaryType {
  fromBeginning,
  sinceLastTime,
  characters,
  resetAll,
}

class SummaryScreen extends StatefulWidget {
  final Book book;
  final ReadingProgress progress;
  final EnhancedSummaryService enhancedSummaryService;
  final String? engineFullText;

  const SummaryScreen({
    super.key,
    required this.book,
    required this.progress,
    required this.enhancedSummaryService,
    this.engineFullText,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final SettingsService _settingsService = SettingsService();
  double _fontSize = 18.0;
  bool _isLoading = true;
  String _summary = '';
  SummaryType _selectedSummaryType = SummaryType.fromBeginning;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _loadFontSize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload font size when screen becomes visible
    _loadFontSize();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final summaryTypeString = prefs.getString('summary_type_${widget.book.id}');
      if (summaryTypeString != null) {
        switch (summaryTypeString) {
          case 'sinceLastTime':
            _selectedSummaryType = SummaryType.sinceLastTime;
            break;
          case 'characters':
            _selectedSummaryType = SummaryType.characters;
            break;
          default:
            _selectedSummaryType = SummaryType.fromBeginning;
        }
      }
      await _loadSummary();
    } catch (e) {
      // If error, use default and continue
      await _loadSummary();
    }
  }

  Future<void> _saveSummaryTypePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String summaryTypeString;
      switch (_selectedSummaryType) {
        case SummaryType.resetAll:
          return;
        case SummaryType.sinceLastTime:
          summaryTypeString = 'sinceLastTime';
          break;
        case SummaryType.characters:
          summaryTypeString = 'characters';
          break;
        default:
          summaryTypeString = 'fromBeginning';
      }
      await prefs.setString('summary_type_${widget.book.id}', summaryTypeString);
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _loadSummary() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Check if background generation is in progress and wait for it
      final backgroundService = BackgroundSummaryService();
      if (backgroundService.isGenerationInProgress(widget.book.id)) {
        // Wait for background generation to complete (with timeout)
        await Future.any([
          backgroundService.waitForGeneration(widget.book.id),
          Future.delayed(const Duration(seconds: 30)), // Timeout after 30 seconds
        ]);
      }

      // Get app language
      final appLocale = Localizations.localeOf(context);
      final languageCode = appLocale.languageCode;

      String summary;
      if (_selectedSummaryType == SummaryType.sinceLastTime) {
        summary = await widget.enhancedSummaryService.getSummarySinceLastTime(
          widget.book,
          widget.progress,
          languageCode,
          preparedEngineText: widget.engineFullText,
        );
      } else if (_selectedSummaryType == SummaryType.characters) {
        summary = await widget.enhancedSummaryService.getCharactersSummary(
          widget.book,
          widget.progress,
          languageCode,
          preparedEngineText: widget.engineFullText,
        );
      } else {
        summary = await widget.enhancedSummaryService.getSummaryUpToPosition(
          widget.book,
          widget.progress,
          languageCode,
          preparedEngineText: widget.engineFullText,
        );
      }

      // Update last summary view position
      final characterIndex = widget.progress.currentCharacterIndex ?? 0;
      final chunkIndex =
          EnhancedSummaryService.computeChunkIndexForCharacterStatic(characterIndex);
      await widget.enhancedSummaryService.updateLastSummaryView(
        widget.book.id,
        chunkIndex,
      );

      if (mounted) {
        setState(() {
          _summary = summary;
          _isLoading = false;
        });
      }
    } catch (e) {
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
        
        setState(() {
          _summary = userFriendlyMessage;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _onSummaryTypeChanged(SummaryType? newType) async {
    if (newType == null || newType == _selectedSummaryType) return;

    if (newType == SummaryType.resetAll) {
      await _resetSummaries();
      return;
    }

    setState(() {
      _selectedSummaryType = newType;
    });

    await _saveSummaryTypePreference();
    await _loadSummary();
  }

  Future<void> _resetSummaries() async {
    setState(() {
      _isLoading = true;
    });

    try {
      await widget.enhancedSummaryService.resetAllSummaries();
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys()
          .where((key) => key.startsWith('summary_type_'))
          .toList();
      for (final key in keys) {
        await prefs.remove(key);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _summary = e.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.resetSummariesError),
        ),
      );
    }
  }

  Future<void> _loadFontSize() async {
    final fontSize = await _settingsService.getFontSize();
    if (mounted) {
      setState(() {
        _fontSize = fontSize;
      });
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
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Summary type dropdown as the title
          Expanded(
            child: DropdownButtonFormField<SummaryType>(
              value: _selectedSummaryType,
              decoration: InputDecoration(
                labelText: l10n.summary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                DropdownMenuItem(
                  value: SummaryType.fromBeginning,
                  child: Text(l10n.summaryFromBeginning),
                ),
                DropdownMenuItem(
                  value: SummaryType.sinceLastTime,
                  child: Text(l10n.summarySinceLastTime),
                ),
                DropdownMenuItem(
                  value: SummaryType.characters,
                  child: Text(l10n.summaryCharacters),
                ),
                DropdownMenuItem(
                  value: SummaryType.resetAll,
                  child: Text(
                    l10n.resetSummaries,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
              onChanged: _onSummaryTypeChanged,
            ),
          ),
          const SizedBox(width: 8),
          // Close button
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8.0),
              child: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

