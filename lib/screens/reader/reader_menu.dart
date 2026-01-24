// ignore_for_file: unused_element

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../../services/rag_database_service.dart';
import '../../services/rag_indexing_service.dart';
import '../../models/rag_index_progress.dart';

enum ReaderMenuAction {
  goToChapter,
  goToPercentage,
  showSavedWords,
  showSummaryFromBeginning,
  showCharactersSummary,
  deleteSummaries,
  askQuestion, // RAG feature
  showLatestEvents, // RAG latest events feature
  openSettings,
  returnToLibrary,
}

/// Displays the reader menu as a modal sheet that slides from the top.
Future<ReaderMenuAction?> showReaderMenu({
  required BuildContext context,
  required double fontScale,
  required ValueChanged<double> onFontScaleChanged,
  required bool hasChapters,
  required bool hasSavedWords,
  required String bookId, // For RAG indexing status
}) {
  return showGeneralDialog<ReaderMenuAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _ReaderMenuDialog(
        initialFontScale: fontScale,
        onFontScaleChanged: onFontScaleChanged,
        hasChapters: hasChapters,
        hasSavedWords: hasSavedWords,
        bookId: bookId,
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final offsetAnimation = Tween<Offset>(
        begin: const Offset(0, -1),
        end: Offset.zero,
      ).animate(curvedAnimation);
      return SlideTransition(
        position: offsetAnimation,
        child: child,
      );
    },
  );
}

class _ReaderMenuDialog extends StatefulWidget {
  const _ReaderMenuDialog({
    required this.initialFontScale,
    required this.onFontScaleChanged,
    required this.hasChapters,
    required this.hasSavedWords,
    required this.bookId,
  });

  final double initialFontScale;
  final ValueChanged<double> onFontScaleChanged;
  final bool hasChapters;
  final bool hasSavedWords;
  final String bookId;

  @override
  State<_ReaderMenuDialog> createState() => _ReaderMenuDialogState();
}

class _ReaderMenuDialogState extends State<_ReaderMenuDialog> {
  late double _currentFontScale;
  final RagDatabaseService _ragDbService = RagDatabaseService();
  final RagIndexingService _ragIndexingService = RagIndexingService();
  RagIndexProgress? _ragIndexProgress;
  StreamSubscription<RagIndexProgress>? _ragIndexingSubscription;
  bool _toastShownForCompletion = false;
  
  // Base font size used in reader_screen.dart
  static const double _baseFontSize = 18.0;

  @override
  void initState() {
    super.initState();
    _currentFontScale = widget.initialFontScale;
    _loadRagIndexStatus();
    _startListeningToRagIndexing();
  }

  @override
  void dispose() {
    _ragIndexingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadRagIndexStatus() async {
    final status = await _ragDbService.getIndexStatus(widget.bookId);
    if (mounted) {
      setState(() {
        _ragIndexProgress = status;
      });
    }
  }

  void _startListeningToRagIndexing() {
    // Listen to RAG indexing progress updates in real-time
    _ragIndexingSubscription = _ragIndexingService.startIndexing(widget.bookId).listen(
      (progress) {
        if (mounted) {
          setState(() {
            _ragIndexProgress = progress;
          });
          _maybeShowCompletionToast(progress);
        }
      },
      onError: (error) {
        debugPrint('[RAG Menu] Error listening to indexing progress: $error');
        // Reload status from database to preserve error state
        if (mounted) {
          _loadRagIndexStatus();
        }
      },
      onDone: () {
        debugPrint('[RAG Menu] Indexing progress stream completed');
        // Reload status from database when stream completes to ensure we have latest state
        if (mounted) {
          _loadRagIndexStatus();
        }
      },
    );
  }

  void _maybeShowCompletionToast(RagIndexProgress progress) {
    if (!progress.isComplete || _toastShownForCompletion) return;
    _toastShownForCompletion = true;
    final chunks = progress.indexedChunks;
    final apiCalls = progress.apiCalls ?? 0;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n?.ragIndexingCompleted(chunks, apiCalls) ?? 'Indexation terminée: $chunks chunks indexés, $apiCalls appels API'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _updateFontScale(double newScale) {
    final clampedScale = newScale.clamp(0.5, 3.0);
    if ((clampedScale - _currentFontScale).abs() < 0.01) return;

    setState(() {
      _currentFontScale = clampedScale;
    });
    // Notify parent immediately so the reader background updates in real-time
    widget.onFontScaleChanged(clampedScale);
  }

  void _incrementFont() {
    _updateFontScale(_currentFontScale + 0.1);
  }

  void _decrementFont() {
    _updateFontScale(_currentFontScale - 0.1);
  }

  void _selectAction(ReaderMenuAction action) {
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final summariesTitle = l10n?.summariesSectionTitle ?? 'Summaries';
    final fromBeginningLabel = l10n?.summaryFromBeginning ?? 'From the Beginning';
    final charactersLabel = l10n?.summaryCharacters ?? 'Characters';

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 12, left: 16, right: 16),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
              bottom: Radius.circular(20),
            ),
            elevation: 12,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n?.readerMenuTitle ?? 'Options de lecture',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings),
                          onPressed: () => _selectAction(ReaderMenuAction.openSettings),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(l10n?.textSize ?? 'Taille du texte'),
                    const SizedBox(height: 8),
                    _FontScaleSelector(
                      fontScale: _currentFontScale,
                      baseFontSize: _baseFontSize,
                      onIncrement: _incrementFont,
                      onDecrement: _decrementFont,
                    ),
                    const SizedBox(height: 8),
                    if (widget.hasChapters)
                      ListTile(
                        leading: const Icon(Icons.list),
                        title: Text(l10n?.goToChapter ?? 'Aller au chapitre'),
                        onTap: () => _selectAction(ReaderMenuAction.goToChapter),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ListTile(
                      leading: const Icon(Icons.percent),
                      title: Text(l10n?.goToPercentage ?? 'Aller à un pourcentage'),
                      onTap: () => _selectAction(ReaderMenuAction.goToPercentage),
                      contentPadding: EdgeInsets.zero,
                    ),
                    ListTile(
                      leading: const Icon(Icons.bookmark),
                      title: Text(l10n?.savedWords ?? 'Mots sauvegardés'),
                      onTap: widget.hasSavedWords
                          ? () => _selectAction(ReaderMenuAction.showSavedWords)
                          : null,
                      enabled: widget.hasSavedWords,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      summariesTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.auto_stories),
                      title: Text(fromBeginningLabel),
                      onTap: () =>
                          _selectAction(ReaderMenuAction.showSummaryFromBeginning),
                      contentPadding: EdgeInsets.zero,
                    ),
                    ListTile(
                      leading: const Icon(Icons.people_outline),
                      title: Text(charactersLabel),
                      onTap: () =>
                          _selectAction(ReaderMenuAction.showCharactersSummary),
                      contentPadding: EdgeInsets.zero,
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: Text(l10n?.summariesDeleteAction ?? 'Supprimer les résumés'),
                      onTap: () => _selectAction(ReaderMenuAction.deleteSummaries),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n?.questionsSectionTitle ?? 'Questions',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    _buildRagQuestionMenuItem(theme),
                    _buildLatestEventsMenuItem(theme, _ragIndexProgress?.isComplete ?? false),
                    ListTile(
                      leading: const Icon(Icons.arrow_back),
                      title: Text(l10n?.backToLibrary ?? 'Retour à la librairie'),
                      onTap: () => _selectAction(ReaderMenuAction.returnToLibrary),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRagQuestionMenuItem(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    if (_ragIndexProgress == null) {
      final progressLabel =
          l10n?.ragIndexingInitializing ?? 'Indexation en cours (...)';
      return ListTile(
        leading: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text(
          progressLabel,
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        enabled: false,
        contentPadding: EdgeInsets.zero,
      );
    }

    final isIndexing = _ragIndexProgress?.isIndexing ?? false;
    final isComplete = _ragIndexProgress?.isComplete ?? false;
    final hasError = _ragIndexProgress?.hasError ?? false;
    final progress = _ragIndexProgress?.progressPercentage ?? 0.0;
    final totalChunks = _ragIndexProgress?.totalChunks ?? 0;
    final errorMessage = _ragIndexProgress?.errorMessage;

    if (isIndexing) {
      final progressLabel = totalChunks == 0
          ? (l10n?.ragIndexingInitializing ?? 'Indexation en cours (...)')
          : (l10n?.ragIndexingProgress(progress.toInt()) ??
              'Indexation en cours (${progress.toStringAsFixed(0)}%)');
      return ListTile(
        leading: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text(
          progressLabel,
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        enabled: false,
        contentPadding: EdgeInsets.zero,
      );
    }

    if (hasError) {
      // Show error state - allow user to see what went wrong
      final skippedChunks = _ragIndexProgress?.skippedChunks ?? 0;
      final indexedChunks = _ragIndexProgress?.indexedChunks ?? 0;
      final totalChunks = _ragIndexProgress?.totalChunks ?? 0;
      
      String shortError;
      if (errorMessage?.contains('API key') == true) {
        shortError = 'Clé API manquante';
      } else if (errorMessage != null && errorMessage.length > 50) {
        shortError = '${errorMessage.substring(0, 50)}...';
      } else {
        shortError = errorMessage ?? 'Erreur d\'indexation';
      }
      
      // Build subtitle with progress and skipped chunks info
      final subtitleParts = <String>[];
      if (totalChunks > 0) {
        if (indexedChunks > 0) {
          subtitleParts.add('$indexedChunks/$totalChunks indexés');
        } else {
          subtitleParts.add('$totalChunks chunks trouvés');
        }
      }
      if (skippedChunks > 0) {
        subtitleParts.add('$skippedChunks ignoré${skippedChunks > 1 ? 's' : ''}');
      }
      
      return ListTile(
        leading: Icon(
          Icons.error_outline,
          color: theme.colorScheme.error.withValues(alpha: 0.7),
        ),
        title: Text(
          shortError,
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.error.withValues(alpha: 0.7),
            fontSize: 13,
          ),
        ),
        subtitle: subtitleParts.isNotEmpty
            ? Text(
                subtitleParts.join(' • '),
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              )
            : null,
        enabled: false,
        contentPadding: EdgeInsets.zero,
      );
    }

    if (!isComplete) {
      return ListTile(
        leading: Icon(
          Icons.help_outline,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        title: Text(
          'Posez une question',
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        enabled: false,
        contentPadding: EdgeInsets.zero,
      );
    }

    return ListTile(
      leading: const Icon(Icons.help_outline),
      title: Text(l10n?.ragAskQuestion ?? 'Poser une question'),
      onTap: () => _selectAction(ReaderMenuAction.askQuestion),
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildLatestEventsMenuItem(ThemeData theme, bool isComplete) {
    final l10n = AppLocalizations.of(context);
    
    return ListTile(
      leading: const Icon(Icons.history),
      title: Text(l10n?.ragLatestEvents ?? 'Quels sont les derniers événements?'),
      onTap: isComplete ? () => _selectAction(ReaderMenuAction.showLatestEvents) : null,
      enabled: isComplete,
      contentPadding: EdgeInsets.zero,
    );
  }
}

class _FontScaleSelector extends StatelessWidget {
  const _FontScaleSelector({
    required this.fontScale,
    required this.baseFontSize,
    required this.onIncrement,
    required this.onDecrement,
  });

  final double fontScale;
  final double baseFontSize;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Determine limits based on logic in _updateFontScale (clamp 0.5 to 3.0)
    final isAtMin = fontScale <= 0.5 + 0.01; 
    final isAtMax = fontScale >= 3.0 - 0.01;
    
    // Calculate accurate effective font size
    final effectiveSize = (baseFontSize * fontScale).round();
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: isAtMin ? null : onDecrement,
          tooltip: 'Réduire la taille',
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            foregroundColor: isAtMin 
                ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
                : theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 16),
        // Display absolute size (e.g. "18", "20") instead of percentage
        Container(
          constraints: const BoxConstraints(minWidth: 40),
          alignment: Alignment.center,
          child: Text(
            effectiveSize.toString(),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              fontSize: 16,
            ),
          ),
        ),
        const SizedBox(width: 16),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: isAtMax ? null : onIncrement,
          tooltip: 'Augmenter la taille',
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            foregroundColor: isAtMax 
                ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
                : theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
