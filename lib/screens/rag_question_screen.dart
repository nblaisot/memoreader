import '../services/rag_progress.dart';
import '../services/rag_answer_style.dart';
import 'dart:typed_data';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import '../services/rag_generation.dart';
import '../services/rag_history_store.dart';
import 'rag_history_screen.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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

class _RagQuestionScreenState extends State<RagQuestionScreen>
    with WidgetsBindingObserver {
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
  bool _onlyReadSoFar = true;

  // Question state
  bool _canSubmit = false;
  bool _isProcessing = false;
  String? _error;
  final List<RagChatTurn> _turns = [];
  RagCancellationToken? _cancellation;
  int _requestEpoch = 0;
  int _retrievalRound = 0;
  String? _pendingQuestion;
  String _partialAnswer = '';
  final _history = RagHistoryStore.instance;
  SummaryConfigService? _summaryConfig;
  String? _conversationId, _activeTurnId, _attemptId;
  String _conversationTitle = '';
  Map<String, String> _savedTitles = {};
  Stopwatch _elapsed = Stopwatch();
  Timer? _ticker, _checkpoint;
  RagStage _stage = RagStage.planning;
  DateTime? _lastActivity;
  List<RagChunk> _activeSources = [], _retryCandidates = [];
  String? _attemptQuestion;
  String _continuationPrefix = '';
  String _t(String en, String fr) =>
      Localizations.localeOf(context).languageCode == 'fr' ? fr : en;
  Set<String> get _missing =>
      _selectedBookIds.where((id) => !_indexedBookIds.contains(id)).toSet();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _questionController.addListener(_handleQuestionChanged);
    unawaited(_loadInitialState());
  }

  @override
  void dispose() {
    _saveActive('interrupted');
    _cancellation?.cancel();
    _ticker?.cancel();
    _checkpoint?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
      saved = await _appStateService.getReaderQuestionBookIds(
        widget.currentBookId!,
      );
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
    if (widget.currentBookId != null &&
        indexed.contains(widget.currentBookId)) {
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
      await _appStateService.setReaderQuestionBookIds(
        widget.currentBookId!,
        ids,
      );
    } else {
      await _appStateService.setLibraryQuestionBookIds(ids);
    }
  }

  void _toggleBook(String bookId, bool selected) {
    if (_isProcessing) _stop();
    setState(() {
      if (selected) {
        _selectedBookIds.add(bookId);
      } else {
        _selectedBookIds.remove(bookId);
      }
      _turns.clear();
      _conversationId = null;
      _conversationTitle = '';
    });
    unawaited(_saveSelection());
  }

  void _selectAll() {
    if (_isProcessing) _stop();
    setState(() {
      _selectedBookIds = _indexedBookIds.toSet();
      _turns.clear();
      _conversationId = null;
      _conversationTitle = '';
    });
    unawaited(_saveSelection());
  }

  void _deselectAll() {
    if (_isProcessing) _stop();
    setState(() {
      _selectedBookIds = {};
      _turns.clear();
      _conversationId = null;
      _conversationTitle = '';
    });
    unawaited(_saveSelection());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _saveActive('running');
  }

  Map<String, dynamic> _turnData(String status) => {
    'question': _attemptQuestion,
    'answer': _continuationPrefix + _partialAnswer,
    'status': status,
    'elapsedMs': _elapsed.elapsedMilliseconds,
    'attemptId': _attemptId,
    'boundaries': widget.bookReadPositions,
    'onlyReadSoFar': _onlyReadSoFar,
    'retryCandidates': _retryCandidates.map((c) => c.toJson()).toList(),
  };
  Future<void> _saveActive(String status) async {
    if (_activeTurnId == null || _attemptQuestion == null) return;
    try {
      await _history.saveTurn(
        _activeTurnId!,
        _turnData(status),
        _activeSources,
      );
    } catch (_) {
      if (mounted)
        setState(
          () => _error = _t(
            'Could not save conversation history',
            'Impossible d’enregistrer la discussion',
          ),
        );
    }
  }

  Future<void> _submitQuestion({
    RagChatTurn? retry,
    bool continuation = false,
  }) async {
    final question = retry?.question ?? _questionController.text.trim();
    if (question.isEmpty ||
        _selectedBookIds.isEmpty ||
        _missing.isNotEmpty ||
        _isProcessing)
      return;
    final epoch = ++_requestEpoch;
    final token = RagCancellationToken();
    _cancellation = token;
    _elapsed = Stopwatch()..start();
    final attemptWatch = _elapsed;
    _attemptId = const Uuid().v4();
    _activeTurnId = retry?.turnId ?? const Uuid().v4();
    _conversationId ??= const Uuid().v4();
    if (_conversationTitle.isEmpty) _conversationTitle = question;
    _attemptQuestion = question;
    _continuationPrefix = continuation ? retry!.answer : '';
    _activeSources = retry?.sources ?? [];
    _retryCandidates = retry?.retryCandidates ?? [];
    _lastActivity = null;
    final conversationId = _conversationId!,
        turnId = _activeTurnId!,
        attempt = _attemptId!;
    final titles = {
      ..._savedTitles,
      for (final b in widget.books) b.id: b.title,
    };
    _savedTitles = titles;
    setState(() {
      _isProcessing = true;
      _error = null;
      _retrievalRound = 0;
      _stage = continuation ? RagStage.generation : RagStage.planning;
      _pendingQuestion = question;
      _partialAnswer = '';
      if (retry != null) _turns.removeWhere((t) => t.turnId == retry.turnId);
    });
    _questionController.clear();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _checkpoint?.cancel();
    _checkpoint = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_isProcessing) unawaited(_saveActive('running'));
    });
    try {
      await _history.begin(conversationId, turnId, {
        'title': _conversationTitle,
        'books': _selectedBookIds.toList(),
        'bookTitles': titles,
        'onlyReadSoFar': _onlyReadSoFar,
      }, _turnData('running'));
      await _saveActive('running');
      final info = await PackageInfo.fromPlatform();
      await _history.event(conversationId, turnId, attempt, 'attempt_started', {
        'question': question,
        'kind': continuation
            ? 'continuation'
            : retry == null
            ? 'question'
            : 'retry',
        'appVersion': info.version,
        'build': info.buildNumber,
        'boundaries': widget.bookReadPositions,
      });
      final trace = RagTrace(
        (type, data) {
          if (type == 'sources' || type == 'candidates') {
            final chunks = (data['passages'] as List? ?? [])
                .map(
                  (p) => RagChunk.fromJson(
                    Map<String, dynamic>.from(p as Map),
                    Uint8List(0),
                  ),
                )
                .toList();
            if (epoch == _requestEpoch) {
              if (type == 'sources') {
                _activeSources = chunks;
              } else {
                _retryCandidates = chunks;
              }
            }
          }
          unawaited(
            _history.event(conversationId, turnId, attempt, type, {
              'elapsedMs': attemptWatch.elapsedMilliseconds,
              ...data,
            }),
          );
          if (type == 'request' ||
              type == 'scope' ||
              type == 'context_compacted' ||
              type == 'decision' ||
              type == 'query_completed' ||
              type == 'response' ||
              type == 'headers' ||
              type.endsWith('failure')) {
            debugPrint(
              '[RAG] attempt=$attempt stage=${data['stage']} event=$type elapsedMs=${attemptWatch.elapsedMilliseconds} status=${data['status']} kind=${data['kind']} finish=${data['finishReason']} usage=${data['usage']} model=${data['model']} effort=${data['effort']} budget=${data['maxOutputTokens']} round=${data['round']} inputTokens=${data['uniqueInputTokens']} passages=${data['newPassages']} selected=${(data['keep'] as List?)?.length} gaps=${(data['gaps'] as List?)?.length} sufficient=${data['sufficient']} planningSkipped=${data['planningSkipped']}',
            );
          }
        },
        onActivity: () {
          if (epoch == _requestEpoch) _lastActivity = DateTime.now();
        },
      );
      final prefs = await SharedPreferences.getInstance();
      final service = await (_summaryConfig ??= SummaryConfigService(
        prefs,
      )).getSummaryService();
      if (service == null)
        throw StateError(
          _t(
            'Configure a generation provider in settings.',
            'Configurez un fournisseur dans les paramètres.',
          ),
        );
      if (!mounted || epoch != _requestEpoch) return;
      final language = Localizations.localeOf(context).languageCode;
      void delta(String text) {
        if (mounted && epoch == _requestEpoch)
          setState(() => _partialAnswer += text);
      }

      RagQueryResult result;
      if (continuation) {
        final generated = await RagTrace.run(
          trace,
          () => _ragQueryService.continueAnswer(
            turn: retry!,
            bookTitles: titles,
            summaryService: service,
            language: language,
            cancellationToken: token,
            onAnswerDelta: delta,
          ),
        );
        result = RagQueryResult(
          answer: retry!.answer + generated.text,
          status: generated.status,
          sourceChunks: retry.sources,
        );
      } else {
        result = await RagTrace.run(
          trace,
          () => _ragQueryService.queryMultipleBooks(
            bookIds: _selectedBookIds.toList(),
            bookTitles: titles,
            bookReadPositions: widget.bookReadPositions,
            onlyReadSoFar: _onlyReadSoFar,
            question: question,
            summaryService: service,
            language: language,
            history: List<RagChatTurn>.from(_turns),
            cancellationToken: token,
            retryCandidates: retry?.retryCandidates ?? [],
            onStage: (stage) {
              if (mounted && epoch == _requestEpoch)
                setState(() => _stage = stage);
            },
            onRetrievalRound: (round) {
              if (mounted && epoch == _requestEpoch)
                setState(() => _retrievalRound = round);
            },
            onAnswerDelta: delta,
          ),
        );
      }
      if (epoch != _requestEpoch) return;
      _elapsed.stop();
      _partialAnswer = result.answer;
      _continuationPrefix = '';
      _activeSources = result.sourceChunks;
      _retryCandidates = result.retryCandidates;
      await _saveActive(result.status);
      await _history
          .event(conversationId, turnId, attempt, 'attempt_finished', {
            'status': result.status,
            'elapsedMs': _elapsed.elapsedMilliseconds,
            'diagnostics': result.diagnostics,
          });
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _turns.add(
          RagChatTurn(
            question,
            result.answer,
            result.sourceChunks,
            status: result.status,
            elapsedMs: _elapsed.elapsedMilliseconds,
            turnId: turnId,
            attemptId: attempt,
            retryCandidates: result.retryCandidates,
            usedCompatibilityFallback: result.usedCompatibilityFallback,
          ),
        );
        _isProcessing = false;
        _pendingQuestion = null;
        _partialAnswer = '';
      });
      if (_scrollController.hasClients) {
        unawaited(
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          ),
        );
      }
    } catch (error) {
      if (epoch != _requestEpoch) return;
      _elapsed.stop();
      final cancelled = token.cancelled || error is RagCancelledException;
      final status = cancelled
          ? 'cancelled'
          : _partialAnswer.isNotEmpty || _continuationPrefix.isNotEmpty
          ? 'incomplete'
          : 'failed';
      await _saveActive(status);
      await _history.event(conversationId, turnId, attempt, 'attempt_failed', {
        'kind': cancelled
            ? 'user_cancellation'
            : error is RagGenerationException
            ? error.kind
            : error is FormatException
            ? 'malformed_output'
            : 'application_error',
        'elapsedMs': _elapsed.elapsedMilliseconds,
      });
      if (mounted && epoch == _requestEpoch)
        setState(() {
          _turns.add(
            RagChatTurn(
              question,
              _continuationPrefix + _partialAnswer,
              _activeSources,
              status: status,
              elapsedMs: _elapsed.elapsedMilliseconds,
              turnId: turnId,
              attemptId: attempt,
              retryCandidates: _retryCandidates,
            ),
          );
          _isProcessing = false;
          _pendingQuestion = null;
          _partialAnswer = '';
        });
    } finally {
      if (epoch == _requestEpoch) {
        _ticker?.cancel();
        _checkpoint?.cancel();
        _activeTurnId = null;
        _attemptQuestion = null;
      }
    }
  }

  void _stop() {
    if (!_isProcessing) return;
    _elapsed.stop();
    _ticker?.cancel();
    _checkpoint?.cancel();
    unawaited(_saveActive('cancelled'));
    if (_conversationId != null &&
        _activeTurnId != null &&
        _attemptId != null) {
      unawaited(
        _history.event(
          _conversationId!,
          _activeTurnId!,
          _attemptId!,
          'attempt_cancelled',
          {'elapsedMs': _elapsed.elapsedMilliseconds},
        ),
      );
    }
    _cancellation?.cancel();
    final question = _attemptQuestion ?? _pendingQuestion ?? '';
    _turns.add(
      RagChatTurn(
        question,
        _continuationPrefix + _partialAnswer,
        _activeSources,
        status: 'cancelled',
        elapsedMs: _elapsed.elapsedMilliseconds,
        turnId: _activeTurnId,
        attemptId: _attemptId,
        retryCandidates: _retryCandidates,
      ),
    );
    _requestEpoch++;
    setState(() {
      _isProcessing = false;
      _partialAnswer = '';
      _pendingQuestion = null;
      _activeTurnId = null;
      _attemptQuestion = null;
    });
  }

  void _newChat() {
    _stop();
    setState(() {
      _turns.clear();
      _error = null;
      _conversationId = null;
      _conversationTitle = '';
    });
  }

  Future<void> _openHistory() async {
    if (_isProcessing) return;
    final selected = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => RagHistoryScreen(store: _history)),
    );
    if (selected == null || !mounted) return;
    final turns = await _history.turns(selected['id'] as String);
    if (!mounted) return;
    setState(() {
      _conversationId = selected['id'] as String;
      _conversationTitle = selected['title'] as String;
      _savedTitles = Map<String, String>.from(
        selected['bookTitles'] as Map? ?? {},
      );
      _selectedBookIds = (selected['books'] as List).cast<String>().toSet();
      _onlyReadSoFar = selected['onlyReadSoFar'] as bool? ?? true;
      _turns
        ..clear()
        ..addAll(
          turns.map(
            (t) => RagChatTurn(
              t['question'] as String? ?? '',
              t['answer'] as String? ?? '',
              RagHistoryStore.decodeSources(t),
              status: t['status'] as String? ?? 'interrupted',
              elapsedMs: t['elapsedMs'] as int? ?? 0,
              turnId: t['id'] as String,
              attemptId: t['attemptId'] as String?,
              retryCandidates: RagHistoryStore.decodeSources({
                'sources': t['retryCandidates'] ?? [],
              }),
            ),
          ),
        );
      _error = null;
    });
  }

  String get _progressLabel => ragProgressLabel(
    french: Localizations.localeOf(context).languageCode == 'fr',
    stage: _stage,
    round: _retrievalRound,
    elapsed: _elapsed.elapsed,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ragQuestionScreenTitle),
        backgroundColor: theme.colorScheme.inversePrimary,
        leading: const BackButton(),
        actions: [
          IconButton(
            tooltip: _t('Recent conversations', 'Discussions récentes'),
            onPressed: _isProcessing ? null : _openHistory,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: l10n.ragNewChat,
            onPressed: _newChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isProcessing) ...[
                  Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_progressLabel)),
                    ],
                  ),
                  if (_elapsed.elapsed.inSeconds >= 15)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _lastActivity == null
                            ? _t(
                                'Waiting for the provider. You can stop at any time.',
                                'En attente du fournisseur. Vous pouvez arrêter à tout moment.',
                              )
                            : DateTime.now()
                                      .difference(_lastActivity!)
                                      .inSeconds >
                                  15
                            ? _t(
                                'Waiting for more provider activity.',
                                'En attente de nouvelles données du fournisseur.',
                              )
                            : _t(
                                'The provider is still working.',
                                'Le fournisseur est toujours actif.',
                              ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                _buildQuestionField(l10n),
                const SizedBox(height: 8),
                _buildSubmitButton(l10n),
              ],
            ),
          ),
        ),
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
            for (final turn in _turns) ...[
              _buildAnswerSection(l10n, theme, turn),
              const SizedBox(height: 16),
            ],
            if (_pendingQuestion != null) ...[
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _pendingQuestion!,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (_partialAnswer.isNotEmpty)
                MarkdownBody(
                  data: ragDisplayAnswer(_continuationPrefix + _partialAnswer),
                  selectable: true,
                ),
            ],
            if (_missing.isNotEmpty)
              Text(
                _t('Unavailable selection: ', 'Sélection indisponible : ') +
                    _missing.map((id) => _savedTitles[id] ?? id).join(', '),
              ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              _buildErrorCard(theme, l10n),
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
                  Icon(
                    Icons.menu_book_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      selectionLabel,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  Icon(
                    _selectorExpanded
                        ? Icons.arrow_drop_up
                        : Icons.arrow_drop_down,
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
                        : TextStyle(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
                          ),
                  ),
                  subtitle: !isIndexed
                      ? Text(
                          l10n.ragBookNotIndexed,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
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
          : (val) => setState(() {
              _onlyReadSoFar = val;
              _conversationId = null;
              _conversationTitle = '';
              _turns.clear();
              _conversationId = null;
              _conversationTitle = '';
            }),
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
      maxLines: 3,
      minLines: 1,
      enabled: !_isProcessing,
      textInputAction: TextInputAction.newline,
    );
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Widget _buildSubmitButton(AppLocalizations l10n) {
    final canAsk =
        _canSubmit &&
        !_isProcessing &&
        _selectedBookIds.isNotEmpty &&
        _missing.isEmpty;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isProcessing ? _stop : (canAsk ? _submitQuestion : null),
        icon: Icon(_isProcessing ? Icons.stop : Icons.send),
        label: Text(_isProcessing ? l10n.ragStop : l10n.ragSubmitQuestion),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error
  // ---------------------------------------------------------------------------

  Widget _buildErrorCard(ThemeData theme, AppLocalizations l10n) {
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
          if (_canSubmit && _selectedBookIds.isNotEmpty && _missing.isEmpty)
            TextButton(
              onPressed: () => _submitQuestion(),
              child: Text(l10n.retry),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Answer + sources
  // ---------------------------------------------------------------------------

  Widget _buildAnswerSection(
    AppLocalizations l10n,
    ThemeData theme,
    RagChatTurn turn,
  ) {
    final titleByBookId = {
      ..._savedTitles,
      for (final book in widget.books) book.id: book.title,
    };
    final cited = RegExp(r'\[S(\d+)\]')
        .allMatches(turn.answer)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .toSet();
    final linkedAnswer = ragDisplayAnswer(turn.answer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(turn.question),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarkdownBody(
                data: linkedAnswer,
                selectable: true,
                onTapLink: (text, href, title) {
                  final index = int.tryParse(
                    href?.replaceFirst('source:', '') ?? '',
                  );
                  if (index != null &&
                      index > 0 &&
                      index <= turn.sources.length) {
                    _showPassage(turn.sources[index - 1], titleByBookId);
                  }
                },
              ),
              Text(
                '${_statusLabel(turn.status)} · ${turn.elapsedMs ~/ 1000} s',
                style: theme.textTheme.bodySmall,
              ),
              if (turn.status != 'complete')
                Wrap(
                  children: [
                    TextButton(
                      onPressed: _isProcessing || _missing.isNotEmpty
                          ? null
                          : () => _submitQuestion(retry: turn),
                      child: Text(l10n.retry),
                    ),
                    if (turn.answer.isNotEmpty && turn.sources.isNotEmpty)
                      TextButton(
                        onPressed: _isProcessing || _missing.isNotEmpty
                            ? null
                            : () => _submitQuestion(
                                retry: turn,
                                continuation: true,
                              ),
                        child: Text(
                          _t('Continue answer', 'Continuer la réponse'),
                        ),
                      ),
                  ],
                ),
              if (turn.usedCompatibilityFallback)
                Text(
                  l10n.ragCompatibilityFallback,
                  style: theme.textTheme.bodySmall,
                ),
              if (turn.sources.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l10n.ragSourcesLabel),
                  children: [
                    for (final entry in turn.sources.asMap().entries)
                      ListTile(
                        dense: true,
                        title: Text(
                          '[S${entry.key + 1}] '
                          '${titleByBookId[entry.value.bookId] ?? entry.value.bookId} — '
                          '${entry.value.chapterTitle ?? ''}',
                        ),
                        subtitle: Text(
                          entry.value.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: cited.contains(entry.key + 1)
                            ? const Icon(Icons.format_quote, size: 18)
                            : null,
                        onTap: () => _showPassage(entry.value, titleByBookId),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _statusLabel(String status) => switch (status) {
    'complete' => _t('Completed', 'Terminé'),
    'cancelled' => _t('Cancelled', 'Annulé'),
    'interrupted' => _t('Interrupted', 'Interrompu'),
    'incomplete' => _t('Incomplete', 'Incomplet'),
    _ => _t('Research failed', 'Recherche échouée'),
  };

  void _showPassage(RagChunk chunk, Map<String, String> titles) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FractionallySizedBox(
            heightFactor: 0.65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${titles[chunk.bookId] ?? chunk.bookId} — '
                  '${chunk.chapterTitle ?? ''}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(chunk.text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
