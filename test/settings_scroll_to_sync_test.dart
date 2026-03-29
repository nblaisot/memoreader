import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal reproduction of the SettingsScreen scroll-to-sync pattern:
/// - Loading phase → async delay → body with SingleChildScrollView + Column
/// - GlobalKey on a widget far down the list
/// - ScrollController + getOffsetToReveal to auto-scroll when [scrollToSync]
///
/// This proves the mechanism works in isolation.
class _FakeSettingsScreen extends StatefulWidget {
  const _FakeSettingsScreen({this.scrollToSync = false});
  final bool scrollToSync;

  @override
  State<_FakeSettingsScreen> createState() => _FakeSettingsScreenState();
}

class _FakeSettingsScreenState extends State<_FakeSettingsScreen> {
  bool _isLoading = true;
  final GlobalKey _targetKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _simulateLoad();
  }

  Future<void> _simulateLoad() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    setState(() => _isLoading = false);
    _scrollToTargetIfRequested();
  }

  void _scrollToTargetIfRequested() {
    if (!widget.scrollToSync || !mounted) return;

    Future<void> runScroll() async {
      for (var i = 0; i < 150; i++) {
        if (!mounted) return;
        if (i > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (!mounted) return;
        }
        final renderObject =
            _targetKey.currentContext?.findRenderObject();
        final controller = _scrollController;
        if (renderObject != null &&
            renderObject.attached &&
            controller.hasClients) {
          final viewport = RenderAbstractViewport.maybeOf(renderObject);
          if (viewport != null) {
            final revealed = viewport.getOffsetToReveal(
                renderObject, 0.0,
                axis: Axis.vertical);
            final min = controller.position.minScrollExtent;
            final max = controller.position.maxScrollExtent;
            if (revealed.offset.isFinite) {
              final target = revealed.offset.clamp(min, max);
              await controller.animateTo(
                target,
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeInOut,
              );
              return;
            }
          }
        }
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(runScroll());
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Many tall widgets to push the target far below the viewport
            for (var i = 0; i < 20; i++)
              Container(
                height: 100,
                margin: const EdgeInsets.only(bottom: 8),
                color: Colors.grey[300],
                child: Center(child: Text('Section $i')),
              ),
            // The target widget (analogous to Google Drive Sync section)
            KeyedSubtree(
              key: _targetKey,
              child: Container(
                height: 80,
                color: Colors.blue[100],
                child: const Center(
                  child: Text('Google Drive Sync'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'scrollToSync=false: target is in tree but scroll stays at top',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _FakeSettingsScreen(scrollToSync: false)),
      );
      // Let loading finish: use the same pattern as the passing test
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // With SingleChildScrollView, target is always built
      expect(find.text('Google Drive Sync'), findsOneWidget);

      // Scroll should be at top
      final sv = tester.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView));
      expect(sv.controller!.offset, 0.0);
    },
  );

  testWidgets(
    'scrollToSync=true scrolls down to the target widget',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _FakeSettingsScreen(scrollToSync: true)),
      );
      // Let loading finish
      await tester.pump();
      await tester.pump();
      // Let post-frame callback fire + scroll animation complete
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Google Drive Sync'), findsOneWidget);

      final sv = tester.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView));
      expect(sv.controller!.offset, greaterThan(0.0),
          reason: 'Scroll offset must be > 0 after auto-scrolling to target');
    },
  );
}
