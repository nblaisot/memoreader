import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import '../services/settings_service.dart';

/// Menu overlay widget for the reader screen
/// 
/// Displays a dropdown menu with options for:
/// - Font size adjustment
/// - Summary access
/// - Important words access
/// - Chapter navigation
/// - Page navigation
/// - Back to library
class ReaderMenu extends StatelessWidget {
  final double fontSize;
  final SettingsService settingsService;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onSummaryTap;
  final VoidCallback onImportantWordsTap;
  final VoidCallback onChaptersTap;
  final VoidCallback onGoToPageTap;
  final VoidCallback onBackTap;

  const ReaderMenu({
    super.key,
    required this.fontSize,
    required this.settingsService,
    required this.onFontSizeChanged,
    required this.onSummaryTap,
    required this.onImportantWordsTap,
    required this.onChaptersTap,
    required this.onGoToPageTap,
    required this.onBackTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          // This will be handled by parent to close menu
        },
        child: Stack(
          children: [
            // Semi-transparent backdrop
            Container(
              color: Colors.black54,
            ),
            // Dropdown menu
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: GestureDetector(
                  onTap: () {
                    // Prevent closing menu when tapping on menu itself
                  },
                  child: Container(
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(20),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Text size slider as first entry
                        _buildFontSizeSlider(context, l10n),
                        const Divider(),
                        // Menu items
                        ListTile(
                          leading: const Icon(Icons.summarize),
                          title: Text(l10n.summary),
                          onTap: onSummaryTap,
                        ),
                        ListTile(
                          leading: const Icon(Icons.text_fields),
                          title: Text(l10n.importantWords),
                          onTap: onImportantWordsTap,
                        ),
                        const Divider(),
                        ListTile(
                          leading: const Icon(Icons.list),
                          title: Text(l10n.chapters),
                          onTap: onChaptersTap,
                        ),
                        ListTile(
                          leading: const Icon(Icons.pageview),
                          title: Text(l10n.goToPage),
                          onTap: onGoToPageTap,
                        ),
                        const Divider(),
                        ListTile(
                          leading: const Icon(Icons.arrow_back),
                          title: Text(l10n.backToLibrary),
                          onTap: onBackTap,
                        ),
                      ],
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

  /// Build the font size slider widget
  Widget _buildFontSizeSlider(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 16.0,
        vertical: 8.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.text_fields),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  l10n.textSize,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
              Text(
                fontSize.toStringAsFixed(0),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          Slider(
            value: fontSize,
            min: settingsService.minFontSize,
            max: settingsService.maxFontSize,
            divisions: 20,
            onChanged: onFontSizeChanged,
          ),
        ],
      ),
    );
  }
}

