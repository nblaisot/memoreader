import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../services/settings_service.dart';
import '../services/summary_service.dart';
import '../models/book.dart';
import '../models/reading_progress.dart';

enum SummaryType {
  fromBeginning,
  sinceLastTime,
  characters,
}

class SummaryScreen extends StatefulWidget {
  final Book book;
  final ReadingProgress progress;
  final SummaryService summaryService;

  const SummaryScreen({
    super.key,
    required this.book,
    required this.progress,
    required this.summaryService,
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
    // Reload font size when screen becomes visible (e.g., returning from settings)
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
      String summary;
      if (_selectedSummaryType == SummaryType.sinceLastTime) {
        summary = await widget.summaryService.getSummarySinceLastTime(
          widget.book,
          widget.progress,
        );
      } else if (_selectedSummaryType == SummaryType.characters) {
        summary = await widget.summaryService.getCharactersSummary(
          widget.book,
          widget.progress,
        );
      } else {
        summary = await widget.summaryService.getSummaryUpToPosition(
          widget.book,
          widget.progress,
        );
      }

      // Update last summary view position
      await widget.summaryService.updateLastSummaryView(
        widget.book.id,
        widget.progress.currentChapterIndex,
      );

      if (mounted) {
        setState(() {
          _summary = summary;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _summary = 'Error loading summary: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _onSummaryTypeChanged(SummaryType? newType) async {
    if (newType == null || newType == _selectedSummaryType) return;

    setState(() {
      _selectedSummaryType = newType;
    });

    await _saveSummaryTypePreference();
    await _loadSummary();
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
        backgroundColor: const Color(0xFFF5F5F0), // Light beige/cream background to differentiate from reader
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

