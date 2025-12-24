import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/book.dart';
import '../models/saved_translation.dart';
import '../services/saved_translation_database_service.dart';
import '../l10n/app_localizations.dart';

class SavedWordsScreen extends StatefulWidget {
  const SavedWordsScreen({super.key, required this.book});

  final Book book;

  @override
  State<SavedWordsScreen> createState() => _SavedWordsScreenState();
}

class _SavedWordsScreenState extends State<SavedWordsScreen> {
  final SavedTranslationDatabaseService _database = 
      SavedTranslationDatabaseService();
  final TextEditingController _filterController = TextEditingController();
  
  List<SavedTranslation> _translations = [];
  List<SavedTranslation> _filteredTranslations = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTranslations();
    _filterController.addListener(_filterTranslations);
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _loadTranslations() async {
    setState(() {
      _isLoading = true;
    });

    final translations = await _database.getTranslations(widget.book.id);
    
    if (mounted) {
      setState(() {
        _translations = translations;
        _filteredTranslations = translations;
        _isLoading = false;
      });
    }
  }

  void _filterTranslations() {
    final query = _filterController.text.trim();
    
    if (query.isEmpty) {
      setState(() {
        _filteredTranslations = _translations;
      });
      return;
    }

    final lowerQuery = query.toLowerCase();
    setState(() {
      _filteredTranslations = _translations.where((translation) {
        return translation.original.toLowerCase().contains(lowerQuery) ||
            (translation.pronunciation?.toLowerCase().contains(lowerQuery) ?? false) ||
            translation.translation.toLowerCase().contains(lowerQuery);
      }).toList();
    });
  }

  Future<void> _deleteTranslation(SavedTranslation translation) async {
    final l10n = AppLocalizations.of(context)!;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.deleteTranslation),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.deleteTranslationConfirm),
            ),
          ],
        );
      },
    );

    if (confirmed == true && translation.id != null) {
      await _database.deleteTranslation(translation.id!);
      await _loadTranslations();
    }
  }

  Future<void> _copyAsTsv() async {
    final l10n = AppLocalizations.of(context)!;
    
    if (_filteredTranslations.isEmpty) {
      return;
    }

    final buffer = StringBuffer();
    
    for (final translation in _filteredTranslations) {
      buffer.write(widget.book.title);
      buffer.write('\t');
      buffer.write(translation.original);
      buffer.write('\t');
      buffer.write(translation.pronunciation ?? '');
      buffer.write('\t');
      buffer.write(translation.translation);
      buffer.write('\n');
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.tsvCopied),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.savedWords),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'copy_tsv') {
                _copyAsTsv();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'copy_tsv',
                child: Text(l10n.copyAsTsv),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _filterController,
              decoration: InputDecoration(
                hintText: l10n.filterSavedWords,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredTranslations.isEmpty
                    ? Center(
                        child: Text(
                          _filterController.text.isEmpty
                              ? l10n.noSavedWords
                              : 'No results',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredTranslations.length,
                        itemBuilder: (context, index) {
                          final translation = _filteredTranslations[index];
                          return _TranslationRow(
                            translation: translation,
                            onLongPress: () => _deleteTranslation(translation),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _TranslationRow extends StatelessWidget {
  const _TranslationRow({
    required this.translation,
    required this.onLongPress,
  });

  final SavedTranslation translation;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return InkWell(
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Original',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    translation.original,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pronunciation',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    translation.pronunciation ?? '-',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: translation.pronunciation == null
                          ? FontStyle.italic
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Translation',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    translation.translation,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

