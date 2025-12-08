import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'page_content_view.dart';

/// Custom text selection controls that show handles and toolbar immediately
/// without any delays, designed for a smooth reading experience.
///
/// This implementation is completely separate from reader navigation gestures.
class ImmediateTextSelectionControls extends MaterialTextSelectionControls {
  ImmediateTextSelectionControls({
    this.onSelectionAction,
    this.actionLabel,
    this.clearSelection,
    this.isProcessingAction = false,
    this.getSelectedText,
  });

  final ValueChanged<String>? onSelectionAction;
  final String? actionLabel;
  final VoidCallback? clearSelection;
  final bool isProcessingAction;
  final String Function()? getSelectedText;



  @override
  Widget buildToolbar(
    BuildContext context,
    Rect globalEditableRegion,
    double textLineHeight,
    Offset selectionMidpoint,
    List<TextSelectionPoint> endpoints,
    TextSelectionDelegate delegate,
    ValueListenable<ClipboardStatus>? clipboardStatus,
    Offset? lastSecondaryTapDownPosition,
  ) {
    final currentSelectedText = getSelectedText?.call() ?? '';
    debugPrint('buildToolbar called - selectedText: "$currentSelectedText", actionLabel: "$actionLabel"');

    // If we don't have selected text, use the default toolbar
    if (currentSelectedText.isEmpty) {
      debugPrint('No selectedText, using default toolbar');
      return super.buildToolbar(
        context,
        globalEditableRegion,
        textLineHeight,
        selectionMidpoint,
        endpoints,
        delegate,
        clipboardStatus,
        lastSecondaryTapDownPosition,
      );
    }

    // Build enhanced menu items
    final enhancedItems = <ContextMenuButtonItem>[];

    // Add our custom action first
    if (onSelectionAction != null && actionLabel != null && !isProcessingAction) {
      debugPrint('Adding custom action: $actionLabel');
      enhancedItems.add(ContextMenuButtonItem(
        label: actionLabel!,
        onPressed: () {
          delegate.hideToolbar();
          onSelectionAction!(currentSelectedText);
          clearSelection?.call();
        },
      ));
    }

    // Add basic items
    enhancedItems.addAll([
      ContextMenuButtonItem(
        label: 'Copier',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: currentSelectedText));
          delegate.hideToolbar();
          clearSelection?.call();
        },
      ),
      ContextMenuButtonItem(
        label: 'Tout sélectionner',
        onPressed: () {
          delegate.hideToolbar();
          clearSelection?.call();
        },
      ),
    ]);

    debugPrint('Returning enhanced system toolbar with ${enhancedItems.length} items');

    // Calculate a safe anchor point
    // selectionMidpoint can sometimes be too high for large blocks or multi-line selections
    // We try to anchor to the top-center of the selection rect formed by endpoints
    Offset anchor = selectionMidpoint;
    if (endpoints.isNotEmpty) {
      final start = endpoints.first.point;
      final end = endpoints.last.point;
      // Use the top Y of the first point, but horizontally centered between start and end (or just start)
      // Actually, standard behavior is usually centered on the selection.
      // But if the user says "too high", maybe we should lower it.
      // Let's rely on the framework's detailed geometry if possible, but here we just have points.
      
      // If we use the raw endpoints, we can compute a rect.
      final rect = Rect.fromPoints(start, end);
      anchor = rect.topCenter;
    }

    // Return the enhanced system toolbar
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: TextSelectionToolbarAnchors(
        primaryAnchor: anchor,
      ),
      buttonItems: enhancedItems,
    );
  }


  /// Custom method to build enhanced toolbar with our actions
  Widget buildEnhancedToolbar({
    required BuildContext context,
    required Rect globalEditableRegion,
    required double textLineHeight,
    required Offset selectionMidpoint,
    required List<TextSelectionPoint> endpoints,
    required TextSelectionDelegate delegate,
    required ValueListenable<ClipboardStatus>? clipboardStatus,
    required Offset? lastSecondaryTapDownPosition,
    required String selectedText,
    required VoidCallback hideToolbar,
  }) {
    // Get the editable text state to access context menu items
    final editableTextState = context.findAncestorStateOfType<EditableTextState>();
    if (editableTextState == null) {
      // Fallback to basic toolbar
      return super.buildToolbar(
        context,
        globalEditableRegion,
        textLineHeight,
        selectionMidpoint,
        endpoints,
        delegate,
        clipboardStatus,
        lastSecondaryTapDownPosition,
      );
    }

    // Build enhanced menu items with our custom action
    final baseItems = editableTextState.contextMenuButtonItems.toList();
    final enhancedItems = PageContentView.buildSelectionActionItems(
      baseItems: baseItems,
      onSelectionAction: onSelectionAction,
      selectedText: selectedText,
      actionLabel: actionLabel ?? 'Translate',
      clearSelection: clearSelection ?? () {},
      hideToolbar: hideToolbar,
      isProcessingAction: isProcessingAction,
    );

    // Create anchors for the toolbar
    final anchors = TextSelectionToolbarAnchors(
      primaryAnchor: selectionMidpoint,
    );

    // Return the enhanced toolbar
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: enhancedItems,
    );
  }
}

