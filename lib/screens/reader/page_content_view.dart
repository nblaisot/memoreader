import 'package:flutter/material.dart' as material;
import 'package:flutter/material.dart';

import '../../screens/reader/document_model.dart';
import 'immediate_text_selection_controls.dart';

class _BlockOffsetInfo {
  final int startOffset;
  final int endOffset;
  final TextPageBlock block;
  
  _BlockOffsetInfo({
    required this.startOffset,
    required this.endOffset,
    required this.block,
  });
}

class PageContentView extends StatefulWidget {
  const PageContentView({
    super.key,
    required this.content,
    required this.maxWidth,
    required this.maxHeight,
    required this.textHeightBehavior,
    required this.textScaler,
    required this.actionLabel,
    required this.onSelectionAction,
    required this.onSelectionChanged,
    required this.isProcessingAction,
  });

  final PageContent content;
  final double maxWidth;
  final double maxHeight;
  final TextHeightBehavior textHeightBehavior;
  final TextScaler textScaler;
  final String actionLabel;
  final ValueChanged<String>? onSelectionAction;
  final void Function(bool hasSelection, VoidCallback clearSelection)?
      onSelectionChanged;
  final bool isProcessingAction;

  static List<ContextMenuButtonItem> buildSelectionActionItems({
    required List<ContextMenuButtonItem> baseItems,
    required ValueChanged<String>? onSelectionAction,
    required String selectedText,
    required String actionLabel,
    required VoidCallback clearSelection,
    required VoidCallback hideToolbar,
    required bool isProcessingAction,
  }) {
    final items = List<ContextMenuButtonItem>.from(baseItems);
    final trimmedText = selectedText.trim();

    if (trimmedText.isNotEmpty &&
        onSelectionAction != null &&
        !isProcessingAction) {
      items.insert(
        0,
        ContextMenuButtonItem(
          onPressed: () {
            hideToolbar();
            onSelectionAction(trimmedText);
            clearSelection();
          },
          label: actionLabel,
        ),
      );
    }

    return items;
  }

  @override
  State<PageContentView> createState() => _PageContentViewState();
}

class _PageContentViewState extends State<PageContentView> {
  String _selectedText = '';
  int _selectionGeneration = 0;
  final List<_BlockOffsetInfo> _blockOffsets = [];
  final GlobalKey _selectableTextKey = GlobalKey();

  void _clearSelection() {
    _selectedText = '';
    _selectionGeneration++;
    // Hide system toolbar
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final editableTextState = _selectableTextKey.currentContext
            ?.findAncestorStateOfType<EditableTextState>();
        if (editableTextState != null) {
          editableTextState.hideToolbar();
        }
      }
    });
    // Only rebuild when explicitly clearing, not during selection changes
    if (mounted) {
      setState(() {});
    }
  }


  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Build combined text span from all text blocks to enable cross-block selection
    final combinedSpan = _buildCombinedTextSpan();
    
    // If we have only text blocks, use a single SelectableText for better selection
    final hasOnlyTextBlocks = widget.content.blocks.every((b) => b is TextPageBlock);
    
    if (hasOnlyTextBlocks && combinedSpan != null) {
      return SizedBox(
        width: widget.maxWidth,
        height: widget.maxHeight,
        child: Stack(
          children: [
            Center(
              child: SelectableText.rich(
                key: _selectableTextKey,
                combinedSpan,
                textHeightBehavior: widget.textHeightBehavior,
                textScaler: widget.textScaler,
                selectionControls: ImmediateTextSelectionControls(
                  onSelectionAction: widget.onSelectionAction,
                  actionLabel: widget.actionLabel,
                  clearSelection: _clearSelection,
                  isProcessingAction: widget.isProcessingAction,
                  getSelectedText: () => _selectedText,
                ),
                onSelectionChanged: (selection, cause) {
                  final base = selection.baseOffset;
                  final extent = selection.extentOffset;
                  final valid = base >= 0 && extent >= 0;
                  final hasSelection = valid &&
                      (base != extent ||
                          cause == SelectionChangedCause.longPress ||
                          cause == SelectionChangedCause.drag);

                  // Update selected text
                  String? newSelectedText;
                  if (hasSelection && valid && base != extent) {
                    final lower = base < extent ? base : extent;
                    final upper = base < extent ? extent : base;
                    newSelectedText = _extractSelectedText(lower, upper);
                  } else {
                    newSelectedText = '';
                  }

                  // Update internal state
                  _selectedText = newSelectedText ?? '';

                  // Only show toolbar if we have a valid selection
                  if (hasSelection && _selectedText.isNotEmpty) {
                    final editableTextState = _selectableTextKey.currentContext
                        ?.findAncestorStateOfType<EditableTextState>();
                    if (editableTextState != null) {
                      // Schedule toolbar to show on next frame to ensure layout is complete
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                         // Add a small delay to ensure the engine has fully processed the selection geometry
                         // This is necessary because sometimes on the very first selection, the overlay isn't quite ready
                         Future.delayed(const Duration(milliseconds: 100), () {
                           if (mounted) {
                             editableTextState.showToolbar();
                           }
                         });
                      });
                    }
                  }

                  widget.onSelectionChanged?.call(hasSelection, _clearSelection);
                },
              ),
            ),
          ],
        ),
      );
    }
    
    // Fallback to original implementation for pages with images
    final children = <Widget>[];
    for (final block in widget.content.blocks) {
      if (block.spacingBefore > 0) {
        children.add(SizedBox(height: block.spacingBefore));
      }

      if (block is TextPageBlock) {
        children.add(
          SelectableText.rich(
            _buildRichTextSpan(block),
            textAlign: block.textAlign,
            textHeightBehavior: widget.textHeightBehavior,
            textScaler: widget.textScaler,
            selectionControls: ImmediateTextSelectionControls(
              onSelectionAction: widget.onSelectionAction,
              actionLabel: widget.actionLabel,
              clearSelection: _clearSelection,
              isProcessingAction: widget.isProcessingAction,
              getSelectedText: () => _selectedText,
            ),
            contextMenuBuilder: null, // Disable default context menu
            onSelectionChanged: (selection, cause) {
              final base = selection.baseOffset;
              final extent = selection.extentOffset;
              final valid = base >= 0 && extent >= 0;
              final hasSelection = valid &&
                  (base != extent ||
                      cause == SelectionChangedCause.longPress ||
                      cause == SelectionChangedCause.drag);
              final lower = base < extent ? base : extent;
              final upper = base < extent ? extent : base;
              final selected = hasSelection && lower != upper
                  ? block.text.substring(
                      lower.clamp(0, block.text.length),
                      upper.clamp(0, block.text.length),
                    )
                  : '';
              
              // Update internal state
              _selectedText = selected;
              // Only show toolbar if we have a valid selection
              if (hasSelection && _selectedText.isNotEmpty) {
                final editableTextState = _selectableTextKey.currentContext
                    ?.findAncestorStateOfType<EditableTextState>();
                if (editableTextState != null) {
                   // Schedule toolbar to show on next frame
                   WidgetsBinding.instance.addPostFrameCallback((_) {
                     // Add a small delay to ensure the engine has fully processed the selection geometry
                     Future.delayed(const Duration(milliseconds: 100), () {
                       if (mounted) {
                         editableTextState.showToolbar();
                       }
                     });
                   });
                }
              }

              widget.onSelectionChanged?.call(hasSelection, _clearSelection);
            },
          ),
        );
      } else if (block is ImagePageBlock) {
        children.add(
          SizedBox(
            height: block.height,
            width: widget.maxWidth,
            child: material.Image.memory(
              block.bytes,
              fit: BoxFit.contain,
            ),
          ),
        );
      }

      if (block.spacingAfter > 0) {
        children.add(SizedBox(height: block.spacingAfter));
      }
    }

    return SizedBox(
      key: ValueKey(_selectionGeneration),
      width: widget.maxWidth,
      height: widget.maxHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.max,
        children: children,
      ),
    );
  }

  TextSpan? _buildCombinedTextSpan() {
    final textSpans = <InlineSpan>[];
    int currentOffset = 0;
    _blockOffsets.clear();
    
    for (final block in widget.content.blocks) {
      if (block is TextPageBlock) {
        _blockOffsets.add(_BlockOffsetInfo(
          startOffset: currentOffset,
          endOffset: currentOffset + block.text.length,
          block: block,
        ));
        
        // Add spacing before as newlines
        if (block.spacingBefore > 0) {
          final newlineCount = (block.spacingBefore / 20).ceil(); // Approximate
          textSpans.add(TextSpan(text: '\n' * newlineCount));
          currentOffset += newlineCount;
        }
        
        // Add the block text
        final blockSpan = _buildRichTextSpan(block);
        textSpans.add(blockSpan);
        currentOffset += block.text.length;
        
        // Add spacing after as newlines
        if (block.spacingAfter > 0) {
          final newlineCount = (block.spacingAfter / 20).ceil(); // Approximate
          textSpans.add(TextSpan(text: '\n' * newlineCount));
          currentOffset += newlineCount;
        }
      }
    }
    
    if (textSpans.isEmpty) return null;
    
    return TextSpan(
      children: textSpans,
      style: widget.content.blocks.isNotEmpty && widget.content.blocks.first is TextPageBlock
          ? (widget.content.blocks.first as TextPageBlock).baseStyle
          : const TextStyle(),
    );
  }

  String _extractSelectedText(int start, int end) {
    final selectedParts = <String>[];
    for (final blockInfo in _blockOffsets) {
      final blockStart = blockInfo.startOffset;
      final blockEnd = blockInfo.endOffset;
      
      // Check if selection overlaps with this block
      if (end > blockStart && start < blockEnd) {
        final overlapStart = (start - blockStart).clamp(0, blockInfo.block.text.length);
        final overlapEnd = (end - blockStart).clamp(0, blockInfo.block.text.length);
        if (overlapEnd > overlapStart) {
          selectedParts.add(blockInfo.block.text.substring(overlapStart, overlapEnd));
        }
      }
    }
    return selectedParts.join(' ');
  }

  TextSpan _buildRichTextSpan(TextPageBlock block) {
    final fragments = block.fragments;
    if (fragments.isEmpty) {
      return TextSpan(
        text: block.text,
        style: block.baseStyle,
      );
    }
    final children = <InlineSpan>[];
    for (final fragment in fragments) {
      if (fragment.type == InlineFragmentType.text &&
          fragment.text != null &&
          fragment.text!.isNotEmpty) {
        children.add(
          TextSpan(
            text: fragment.text,
            style: fragment.style ?? block.baseStyle,
          ),
        );
      } else if (fragment.type == InlineFragmentType.image &&
          fragment.image != null) {
        final image = fragment.image!;
        children.add(
          WidgetSpan(
            alignment: image.alignment,
            baseline: image.baseline,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.maxWidth,
                maxHeight: widget.maxHeight * 0.6,
              ),
              child: material.Image.memory(
                image.bytes,
                fit: BoxFit.contain,
              ),
            ),
          ),
        );
      }
    }
    return TextSpan(
      style: block.baseStyle.copyWith(height: block.lineHeight),
      children: children,
    );
  }
}
