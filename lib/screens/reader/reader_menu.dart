import 'dart:async';

import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';

/// Displays the reader menu as a modal sheet that slides from the top.
Future<void> showReaderMenu({
  required BuildContext context,
  required double fontScale,
  required VoidCallback onFontScaleIncrement,
  required VoidCallback onFontScaleDecrement,
  required bool hasChapters,
  required VoidCallback onGoToChapter,
  required VoidCallback onGoToPercentage,
  required VoidCallback onShowSummaryFromBeginning,
  required VoidCallback onShowCharactersSummary,
  required VoidCallback onDeleteSummaries,
  required VoidCallback onReturnToLibrary,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      void closeMenu() {
        Navigator.of(dialogContext).pop();
      }

      void handleAction(VoidCallback action) {
        closeMenu();
        Future.microtask(action);
      }

      return _ReaderMenuDialog(
        fontScale: fontScale,
        onFontScaleIncrement: onFontScaleIncrement,
        onFontScaleDecrement: onFontScaleDecrement,
        hasChapters: hasChapters,
        onGoToChapter: () => handleAction(onGoToChapter),
        onGoToPercentage: () => handleAction(onGoToPercentage),
        onShowSummaryFromBeginning:
            () => handleAction(onShowSummaryFromBeginning),
        onShowCharactersSummary: () => handleAction(onShowCharactersSummary),
        onDeleteSummaries: () => handleAction(onDeleteSummaries),
        onReturnToLibrary: () => handleAction(onReturnToLibrary),
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
    required this.fontScale,
    required this.onFontScaleIncrement,
    required this.onFontScaleDecrement,
    required this.hasChapters,
    required this.onGoToChapter,
    required this.onGoToPercentage,
    required this.onShowSummaryFromBeginning,
    required this.onShowCharactersSummary,
    required this.onDeleteSummaries,
    required this.onReturnToLibrary,
  });

  final double fontScale;
  final VoidCallback onFontScaleIncrement;
  final VoidCallback onFontScaleDecrement;
  final bool hasChapters;
  final VoidCallback onGoToChapter;
  final VoidCallback onGoToPercentage;
  final VoidCallback onShowSummaryFromBeginning;
  final VoidCallback onShowCharactersSummary;
  final VoidCallback onDeleteSummaries;
  final VoidCallback onReturnToLibrary;

  @override
  State<_ReaderMenuDialog> createState() => _ReaderMenuDialogState();
}

class _ReaderMenuDialogState extends State<_ReaderMenuDialog> {

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
                            'Options de lecture',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('Taille du texte'),
                    const SizedBox(height: 8),
                    _FontScaleSelector(
                      fontScale: widget.fontScale,
                      onIncrement: widget.onFontScaleIncrement,
                      onDecrement: widget.onFontScaleDecrement,
                    ),
                    const SizedBox(height: 8),
                    if (widget.hasChapters)
                      ListTile(
                        leading: const Icon(Icons.list),
                        title: const Text('Aller au chapitre'),
                        onTap: widget.onGoToChapter,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ListTile(
                      leading: const Icon(Icons.percent),
                      title: const Text('Aller à un pourcentage'),
                      onTap: widget.onGoToPercentage,
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
                      onTap: widget.onShowSummaryFromBeginning,
                      contentPadding: EdgeInsets.zero,
                    ),
                    ListTile(
                      leading: const Icon(Icons.people_outline),
                      title: Text(charactersLabel),
                      onTap: widget.onShowCharactersSummary,
                      contentPadding: EdgeInsets.zero,
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: Text(l10n?.summariesDeleteAction ?? 'Supprimer les résumés'),
                      onTap: widget.onDeleteSummaries,
                      contentPadding: EdgeInsets.zero,
                    ),
                    ListTile(
                      leading: const Icon(Icons.arrow_back),
                      title: const Text('Retour à la librairie'),
                      onTap: widget.onReturnToLibrary,
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
}

class _FontScaleSelector extends StatelessWidget {
  const _FontScaleSelector({
    required this.fontScale,
    required this.onIncrement,
    required this.onDecrement,
  });

  final double fontScale;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAtMin = fontScale <= 0.5;
    final isAtMax = fontScale >= 2.0;
    
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
        Text(
          '${(fontScale * 100).toStringAsFixed(0)}%',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
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
