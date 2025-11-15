import 'dart:async';

import 'package:flutter/material.dart';

/// Displays the reader menu as a modal sheet that slides from the top.
Future<void> showReaderMenu({
  required BuildContext context,
  required double fontSize,
  required ValueChanged<double> onFontSizeChanged,
  required bool hasChapters,
  required VoidCallback onGoToChapter,
  required VoidCallback onGoToPercentage,
  required VoidCallback onShowSummaries,
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
        fontSize: fontSize,
        onFontSizeChanged: onFontSizeChanged,
        hasChapters: hasChapters,
        onGoToChapter: () => handleAction(onGoToChapter),
        onGoToPercentage: () => handleAction(onGoToPercentage),
        onShowSummaries: () => handleAction(onShowSummaries),
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
    required this.fontSize,
    required this.onFontSizeChanged,
    required this.hasChapters,
    required this.onGoToChapter,
    required this.onGoToPercentage,
    required this.onShowSummaries,
    required this.onReturnToLibrary,
  });

  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;
  final bool hasChapters;
  final VoidCallback onGoToChapter;
  final VoidCallback onGoToPercentage;
  final VoidCallback onShowSummaries;
  final VoidCallback onReturnToLibrary;

  @override
  State<_ReaderMenuDialog> createState() => _ReaderMenuDialogState();
}

class _ReaderMenuDialogState extends State<_ReaderMenuDialog> {
  late double _sliderValue;

  @override
  void initState() {
    super.initState();
    _sliderValue = widget.fontSize;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                    Text('Taille du texte : ${_sliderValue.toStringAsFixed(0)} pt'),
                    Slider(
                      min: 14,
                      max: 30,
                      divisions: 16,
                      label: '${_sliderValue.toStringAsFixed(0)} pt',
                      value: _sliderValue,
                      onChanged: (value) {
                        setState(() => _sliderValue = value);
                        widget.onFontSizeChanged(value);
                      },
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
                    ListTile(
                      leading: const Icon(Icons.summarize),
                      title: const Text('Résumés'),
                      onTap: widget.onShowSummaries,
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
