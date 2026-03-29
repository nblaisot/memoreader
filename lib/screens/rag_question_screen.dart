import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';
import '../models/book.dart';
import '../models/rag_chunk.dart';
import '../services/app_state_service.dart';
import '../services/rag_query_service.dart';
import '../services/rag_database_service.dart';
import '../services/summary_config_service.dart';
/// Full-screen widget for asking RAG questions over one or multiple books.
///
/// When [currentBookId] is null, the screen is in "library" context:
/// - book selection is saved/loaded under the library-wide preference key
/// - default selection is all indexed books
///
/// When [currentBookId] is set, the screen is in "reader" context:
/// - book selection is saved/loaded under a per-book preference key
/// - default selection is just [currentBookId]
class RagQuestionScreen extends StatefulWidget {
  const RagQuestionScreen({
    super.key,
    required this.books,
    this.currentBookId,
    required this.bookReadPositions,
  });

  /// All books in the library.
  final List<Book> books;

  /// The book currently open in the reader, or null when invoked from library.
  final String? currentBookId;

  /// Map of bookId to the user's current read position (charIndex).
  /// null value means no progress recorded for that book.
  final Map<String, int?> bookReadPositions;

  @override
  State<RagQuestionScreen> createState() => _RagQuestionScreenState();
}

class _RagQuestionScreenState extends State<RagQuestionScreen> {
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final RagQueryService _ragQueryService = RagQueryService();
  final RagDatabaseService _ragDbService = RagDatabaseService();
  final AppStateService _appStateService = AppStateService();

  // Book selector state
  List<String> _indexedBookIds = [];
  Set<String> _selectedBookIds = {};
  bool _selectorExpanded = false;

  // Toggle
  bool _onlyReadSoFar = false;

  // Question state
  bool _canSubmit = false;
  bool _isProcessing = false;
  String? _answer;
  String? _error;
  List<RagChunk> _sourceChunks = [];

  @override
  void initState() {
    super.initState();
    _questionController.addListener(_handleQuestionChanged);
    unawaited(_loadInitialState());
  }

  @override
  void dispose() {
    _questionController.removeListener(_handleQuestionChanged);
    _questionController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    // Find all indexed book IDs
    final indexed = await _ragDbService.getAllIndexedBookIds();

    // Determine saved selection
    List<String>? saved;
    if (widget.currentBookId != null) {
      saved = await _appStateService.getReaderQuestionBookIds(widget.currentBookId!);
    } else {
      saved = await _appStateService.getLibraryQuestionBookIds();
    }

    Set<String> initial;
    if (saved != null) {
      // Use saved selection, but only include books that are still indexed
      initial = saved.where(indexed.contains).toSet();
      // If the saved selection became empty (e.g. books deleted), fall back to default
      if (initial.isEmpty) {
        initial = _defaultSelection(indexed);
      }
    } else {
      initial = _defaultSelection(indexed);
    }

    if (mounted) {
      setState(() {
        _indexedBookIds = indexed;
        _selectedBookIds = initial;
      });
    }
  }

  Set<String> _defaultSelection(List<String> indexed) {
    if (widget.currentBookId != null && indexed.contains(widget.currentBookId)) {
      return {widget.currentBookId!};
    }
    // Library context: select all
    return indexed.toSet();
  }

  void _handleQuestionChanged() {
    final hasText = _questionController.text.trim().isNotEmpty;
    if (hasText != _canSubmit && mounted) {
      setState(() => _canSubmit = hasText);
    }
  }

  Future<void> _saveSelection() async {
    final ids = _selectedBookIds.toList();
    if (widget.currentBookId != null) {
      await _appStateService.setReaderQuestionBookIds(widget.currentBookId!, ids);
    } else {
      await _appStateService.setLibraryQuestionBookIds(ids);
    }
  }

  void _toggleBook(String bookId, bool selected) {
    setState(() {
      if (selected) {
        _selectedBookIds.add(bookId);
      } else {
        _selectedBookIds.remove(bookId);
      }
    });
    unawaited(_saveSelection());
  }

  void _selectAll() {
    setState(() => _selectedBookIds = _indexedBookIds.toSet());
    unawaited(_saveSelection());
  }

  void _deselectAll() {
    setState(() => _selectedBookIds = {});
    unawaited(_saveSelection());
  }

  Future<void> _submitQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty || _selectedBookIds.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _answer = null;
      _error = null;
      _sourceChunks = [];
    });

    // Scroll past the question field to show progress
    await Future.delayed(const Duration(milliseconds: 100));
    if (_scrollController.hasClients) {
      unawaited(_scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ));
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final configService = SummaryConfigService(prefs);
      final baseService = await configService.getSummaryService();
      if (baseService == null) {
        throw Exception('Summary service not available. Please configure an API key in settings.');
      }

      if (!mounted) return;
      final language = AppLocalizations.of(context)!.localeName.split('_')[0];

      final bookTitles = <String, String>{};
      for (final book in widget.books) {
        bookTitles[book.id] = book.title;
      }

      final result = await _ragQueryService.queryMultipleBooks(
        bookIds: _selectedBookIds.toList(),
        bookTitles: bookTitles,
        bookReadPositions: widget.bookReadPositions,
        onlyReadSoFar: _onlyReadSoFar,
        question: question,
        summaryService: baseService,
        language: language,
      );

      if (mounted) {
        setState(() {
          _answer = result.answer;
          _sourceChunks = result.sourceChunks;
          _isProcessing = false;
        });
        // Scroll to answer
        await Future.delayed(const Duration(milliseconds: 100));
        if (_scrollController.hasClients) {
          unawaited(_scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          ));
        }
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
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ragQuestionScreenTitle),
        backgroundColor: theme.colorScheme.inversePrimary,
        leading: const BackButton(),
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildBookSelector(l10n, theme),
            const SizedBox(height: 16),
            _buildAlreadyReadToggle(l10n),
            const SizedBox(height: 16),
            _buildQuestionField(l10n),
            const SizedBox(height: 16),
            _buildSubmitButton(l10n),
            if (_isProcessing) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              _buildErrorCard(theme),
            ],
            if (_answer != null) ...[
              const SizedBox(height: 16),
              _buildAnswerSection(l10n, theme),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Book selector
  // ---------------------------------------------------------------------------

  Widget _buildBookSelector(AppLocalizations l10n, ThemeData theme) {
    final sortedBooks = List<Book>.from(widget.books)
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final selectionLabel = _buildSelectionLabel(l10n);

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            onTap: () => setState(() => _selectorExpanded = !_selectorExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      selectionLabel,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  Icon(
                    _selectorExpanded ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    color: theme.colorScheme.onSurface,
                  ),
                ],
              ),
            ),
          ),
          if (_selectorExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _selectAll,
                    child: Text(l10n.ragSelectAll),
                  ),
                  TextButton(
                    onPressed: _deselectAll,
                    child: Text(l10n.ragDeselectAll),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: sortedBooks.length,
              itemBuilder: (context, index) {
                final book = sortedBooks[index];
                final isIndexed = _indexedBookIds.contains(book.id);
                final isSelected = _selectedBookIds.contains(book.id);
                return CheckboxListTile(
                  title: Text(
                    book.title,
                    style: isIndexed
                        ? null
                        : TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                  ),
                  subtitle: !isIndexed
                      ? Text(
                          l10n.ragBookNotIndexed,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                        )
                      : null,
                  value: isIndexed ? isSelected : false,
                  onChanged: isIndexed
                      ? (val) => _toggleBook(book.id, val ?? false)
                      : null,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  String _buildSelectionLabel(AppLocalizations l10n) {
    if (_selectedBookIds.isEmpty) {
      return l10n.ragAllBooks;
    }
    if (_selectedBookIds.length == _indexedBookIds.length) {
      return l10n.ragAllBooks;
    }
    return l10n.ragBooksSelected(_selectedBookIds.length);
  }

  // ---------------------------------------------------------------------------
  // Already read toggle
  // ---------------------------------------------------------------------------

  Widget _buildAlreadyReadToggle(AppLocalizations l10n) {
    return SwitchListTile(
      title: Text(l10n.ragAlreadyRead),
      value: _onlyReadSoFar,
      onChanged: _isProcessing
          ? null
          : (val) => setState(() => _onlyReadSoFar = val),
      contentPadding: EdgeInsets.zero,
    );
  }

  // ---------------------------------------------------------------------------
  // Question field
  // ---------------------------------------------------------------------------

  Widget _buildQuestionField(AppLocalizations l10n) {
    return TextField(
      controller: _questionController,
      decoration: InputDecoration(
        labelText: l10n.ragQuestionField,
        hintText: l10n.ragQuestionField,
        border: const OutlineInputBorder(),
      ),
      maxLines: 4,
      minLines: 2,
      enabled: !_isProcessing,
      textInputAction: TextInputAction.newline,
    );
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Widget _buildSubmitButton(AppLocalizations l10n) {
    final canAsk = _canSubmit && !_isProcessing && _selectedBookIds.isNotEmpty;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: canAsk ? _submitQuestion : null,
        icon: const Icon(Icons.send),
        label: Text(l10n.ragSubmitQuestion),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error
  // ---------------------------------------------------------------------------

  Widget _buildErrorCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
    );
  }

  // ---------------------------------------------------------------------------
  // Answer + sources
  // ---------------------------------------------------------------------------

  Widget _buildAnswerSection(AppLocalizations l10n, ThemeData theme) {
    // Collect unique book IDs from source chunks
    final sourceBookIds = _sourceChunks.map((c) => c.bookId).toSet();
    final sourceTitles = widget.books
        .where((b) => sourceBookIds.contains(b.id))
        .map((b) => b.title)
        .toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.ragAnswerLabel,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
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
        if (sourceTitles.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            l10n.ragSourcesLabel,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          ...sourceTitles.map(
            (title) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(Icons.book_outlined, size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(title, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
