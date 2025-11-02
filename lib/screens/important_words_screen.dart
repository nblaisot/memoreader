import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../services/important_words_service.dart';
import '../models/book.dart';

class ImportantWordsScreen extends StatefulWidget {
  final Book book;
  final ImportantWordsService importantWordsService;

  const ImportantWordsScreen({
    super.key,
    required this.book,
    required this.importantWordsService,
  });

  @override
  State<ImportantWordsScreen> createState() => _ImportantWordsScreenState();
}

class _ImportantWordsScreenState extends State<ImportantWordsScreen> {
  static const double _regularFontSize = 14.0; // Regular font size for table formatting
  bool _isLoading = true;
  String _importantWords = '';

  @override
  void initState() {
    super.initState();
    _loadImportantWords();
  }

  Future<void> _loadImportantWords() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final importantWords = await widget.importantWordsService.getImportantWords(
        widget.book,
      );

      if (mounted) {
        setState(() {
          _importantWords = importantWords;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _importantWords = 'Error loading important words: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F0), // Light beige/cream background
        appBar: AppBar(
          title: Text(l10n.importantWords),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l10n.generatingImportantWords),
            ],
          ),
        ),
      );
    }

    if (_importantWords.isEmpty && !_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F0),
        appBar: AppBar(
          title: Text(l10n.importantWords),
        ),
        body: SafeArea(
          child: Center(
            child: Text(l10n.noContentAvailable),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F0),
      appBar: AppBar(
        title: Text(l10n.importantWords),
      ),
      body: SafeArea(
        child: Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: MarkdownBody(
              data: _importantWords,
              styleSheet: MarkdownStyleSheet(
                p: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: _regularFontSize,
                  height: 1.5,
                ),
                tableHead: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: _regularFontSize,
                  fontWeight: FontWeight.bold,
                ),
                tableBody: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: _regularFontSize,
                  height: 1.5,
                ),
                tableHeadAlign: TextAlign.center,
                tableCellsPadding: const EdgeInsets.all(8.0),
                tableBorder: TableBorder.all(
                  color: Colors.grey[400]!,
                  width: 1,
                ),
                h1: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: _regularFontSize * 1.5,
                  fontWeight: FontWeight.bold,
                ),
                h2: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: _regularFontSize * 1.3,
                  fontWeight: FontWeight.bold,
                ),
                h3: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: _regularFontSize * 1.2,
                  fontWeight: FontWeight.bold,
                ),
                strong: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: _regularFontSize,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: WrapAlignment.start,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

