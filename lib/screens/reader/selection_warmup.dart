import 'package:flutter/material.dart';
import 'immediate_text_selection_controls.dart';

/// A utility widget that "warms up" the text selection system by pre-triggering
/// the code paths that would normally run on first selection.
///
/// In debug mode, Flutter uses JIT compilation, which means the first time
/// the selection overlay is shown, it needs to compile all the related code,
/// causing a noticeable delay (1-3+ seconds). By warming up these code paths
/// early, we ensure the compilation happens before the user tries to select text.
///
/// This widget is invisible and removes itself after warming up.
class SelectionWarmup extends StatefulWidget {
  const SelectionWarmup({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  State<SelectionWarmup> createState() => _SelectionWarmupState();
}

class _SelectionWarmupState extends State<SelectionWarmup> {
  bool _warmupComplete = false;
  final GlobalKey<EditableTextState> _warmupKey = GlobalKey<EditableTextState>();
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      // Schedule warmup after the first frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _performWarmup();
      });
    }
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  void _performWarmup() {
    if (!mounted || _warmupComplete) return;

    // Create overlay entry with SelectableText using ImmediateTextSelectionControls
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: -1000,
        top: -1000,
        child: Opacity(
          opacity: 0,
          child: SizedBox(
            width: 200, // Make it wider to accommodate toolbar
            height: 100, // Make it taller
            child: Material(
              child: SelectableText(
                'Warmup text for selection system compilation',
                key: _warmupKey,
                selectionControls: ImmediateTextSelectionControls( // Use the same controls as the real app
                  onSelectionAction: (text) {}, // Dummy callback
                  actionLabel: 'Traduire', // Same label as real app
                  clearSelection: () {}, // Dummy callback
                  isProcessingAction: false,
                  getSelectedText: () => 'selected text', // Dummy function
                ),
                onSelectionChanged: (selection, cause) {
                  // Once selection happens, we've warmed up the system
                  if (selection.baseOffset != selection.extentOffset) {
                    _completeWarmup();
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);

    // Trigger the warmup after the overlay is inserted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerSelection();
    });
  }

  void _triggerSelection() {
    if (!mounted || _warmupComplete) return;

    final editableState = _warmupKey.currentState;
    if (editableState != null) {
      try {
        // Create a real selection to warm up the selection overlay system
        editableState.updateEditingValue(
          const TextEditingValue(
            text: 'Warmup text for selection system compilation',
            selection: TextSelection(baseOffset: 0, extentOffset: 6),
          ),
        );

        // Actually show the toolbar to warm up the custom buildToolbar logic
        editableState.showToolbar();

        // Keep it visible longer to ensure ALL code is compiled
        Future.delayed(const Duration(milliseconds: 1000), () { // Increased from 500ms
          if (mounted) {
            editableState.hideToolbar();
            editableState.updateEditingValue(
              const TextEditingValue(text: 'Warmup text for selection system compilation'),
            );
            _completeWarmup();
          }
        });
      } catch (e) {
        debugPrint('[SelectionWarmup] Warmup failed: $e');
        _completeWarmup();
      }
    } else {
      Future.delayed(const Duration(milliseconds: 200), () {
        _completeWarmup();
      });
    }
  }

  void _completeWarmup() {
    if (_warmupComplete) return;
    
    _overlayEntry?.remove();
    _overlayEntry = null;
    
    if (mounted) {
      setState(() {
        _warmupComplete = true;
      });
    }
    
    debugPrint('[SelectionWarmup] Text selection system warmed up');
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// A simpler approach: just import and reference the selection-related classes
/// to trigger their code to be loaded/compiled.
///
/// Call this function early (e.g., in main() or during app startup)
/// to pre-load the selection system code.
void warmupSelectionSystem() {
  // Access these classes to ensure their code is loaded
  // This helps with tree-shaking and ensures the code is available
  debugPrint('[SelectionWarmup] Pre-loading selection system...');
  
  // Force the runtime to load these overlay-related classes
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Create a minimal overlay entry to warm up the overlay system
    final overlay = OverlayEntry(
      builder: (context) => const SizedBox.shrink(),
    );
    
    // The entry is created but never inserted - this is enough to warm up
    // some of the overlay infrastructure
    overlay.dispose();
    
    debugPrint('[SelectionWarmup] Selection system pre-loaded');
  });
}
