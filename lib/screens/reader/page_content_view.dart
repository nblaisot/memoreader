import 'package:flutter/material.dart' as material;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

import '../../screens/reader/document_model.dart';

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
  

  void _clearSelection() {
    _selectedText = '';
    _selectionGeneration++;
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
            SelectionArea(
              contextMenuBuilder: (context, editableState) {
                // Get the default menu items
                final defaultItems = editableState.contextMenuButtonItems;

                // Insert "Traduire" at the beginning, after any copy/share options
                final customItems = [
                  ContextMenuButtonItem(
                    label: widget.actionLabel,
                    onPressed: () {
                      final selectedText = _selectedText;
                      if (selectedText.isNotEmpty && widget.onSelectionAction != null) {
                        widget.onSelectionAction!(selectedText);
                        _clearSelection();
                      }
                      // Hide the context menu
                      editableState.hideToolbar();
                    },
                  ),
                  ...defaultItems,
                ];

                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editableState.contextMenuAnchors,
                  buttonItems: customItems,
                );
              },
              onSelectionChanged: (selection) {
                if (selection != null && selection.plainText.isNotEmpty) {
                  // SelectedContent has plainText property with the selected text
                  final selectedText = selection.plainText;
                  final hasSelection = selectedText.isNotEmpty;

                  _selectedText = selectedText;
                  widget.onSelectionChanged?.call(hasSelection, _clearSelection);
                } else {
                  _selectedText = '';
                  widget.onSelectionChanged?.call(false, _clearSelection);
                }
              },
              child: Center(
                child: Text.rich(
                  combinedSpan,
                  textHeightBehavior: widget.textHeightBehavior,
                  textScaler: widget.textScaler,
                ),
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
          SelectionArea(
            contextMenuBuilder: (context, editableState) {
              // Get the default menu items
              final defaultItems = editableState.contextMenuButtonItems;

              // Insert "Traduire" at the beginning, after any copy/share options
              final customItems = [
                ContextMenuButtonItem(
                  label: widget.actionLabel,
                  onPressed: () {
                    final selectedText = _selectedText;
                    if (selectedText.isNotEmpty && widget.onSelectionAction != null) {
                      widget.onSelectionAction!(selectedText);
                      _clearSelection();
                    }
                    // Hide the context menu
                    editableState.hideToolbar();
                  },
                ),
                ...defaultItems,
              ];

              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableState.contextMenuAnchors,
                buttonItems: customItems,
              );
            },
            onSelectionChanged: (selection) {
              if (selection != null && selection.plainText.isNotEmpty) {
                // SelectedContent has plainText property with the selected text
                final selectedText = selection.plainText;
                final hasSelection = selectedText.isNotEmpty;

                _selectedText = selectedText;
                widget.onSelectionChanged?.call(hasSelection, _clearSelection);
              } else {
                _selectedText = '';
                widget.onSelectionChanged?.call(false, _clearSelection);
              }
            },
            child: Text.rich(
              _buildRichTextSpan(block),
              textAlign: block.textAlign,
              textHeightBehavior: widget.textHeightBehavior,
              textScaler: widget.textScaler,
            ),
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

  String _extractWordAtPosition(int position) {
    // Find the block containing this position
    for (final blockInfo in _blockOffsets) {
      if (position >= blockInfo.startOffset && position < blockInfo.endOffset) {
        final localPos = position - blockInfo.startOffset;
        final text = blockInfo.block.text;
        
        if (localPos < 0 || localPos >= text.length) {
          continue;
        }
        
        // Find word boundaries
        int start = localPos;
        int end = localPos;
        
        // Move start backward to word start
        while (start > 0 && _isWordChar(text[start - 1])) {
          start--;
        }
        
        // Move end forward to word end
        while (end < text.length && _isWordChar(text[end])) {
          end++;
        }
        
        if (end > start) {
          return text.substring(start, end);
        }
      }
    }
    return '';
  }
  
  bool _isWordChar(String char) {
    // Word characters: letters, digits, apostrophes, hyphens
    // Using character class that matches word characters plus apostrophe and hyphen
    if (char.isEmpty) return false;
    final codeUnit = char.codeUnitAt(0);
    // Match letters, digits, apostrophe (39), hyphen (45)
    return (codeUnit >= 48 && codeUnit <= 57) || // digits 0-9
        (codeUnit >= 65 && codeUnit <= 90) || // A-Z
        (codeUnit >= 97 && codeUnit <= 122) || // a-z
        codeUnit == 39 || // apostrophe
        codeUnit == 45; // hyphen
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
