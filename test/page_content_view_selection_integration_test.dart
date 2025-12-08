import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/screens/reader/document_model.dart';
import 'package:memoreader/screens/reader/page_content_view.dart';

void main() {
  group('PageContentView selection integration', () {
    testWidgets('long press selects text on FIRST attempt (not second)', (WidgetTester tester) async {
      final blockText = 'Hold to select this text.';
      int selectionChangeCount = 0;
      bool firstAttemptWorked = false;

      final page = PageContent(
        blocks: [
          TextPageBlock(
            text: blockText,
            fragments: [
              const InlineSpanFragment.text(
                text: 'Hold to select this text.',
                style: TextStyle(),
              ),
            ],
            textAlign: TextAlign.left,
            baseStyle: const TextStyle(fontSize: 18),
            spacingBefore: 0,
            spacingAfter: 0,
          ),
        ],
        chapterIndex: 0,
        startWordIndex: 0,
        endWordIndex: blockText.split(' ').length,
        startCharIndex: 0,
        endCharIndex: blockText.length,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en')],
          home: Scaffold(
            body: Center(
              child: PageContentView(
                content: page,
                maxWidth: 400,
                maxHeight: 800,
                textHeightBehavior: const TextHeightBehavior(),
                textScaler: MediaQueryData.fromView(WidgetsBinding.instance.window).textScaler,
                actionLabel: 'Translate',
                onSelectionAction: (_) {},
                onSelectionChanged: (hasSelection, _) {
                  selectionChangeCount++;
                  if (hasSelection && selectionChangeCount == 1) {
                    firstAttemptWorked = true;
                  }
                },
                isProcessingAction: false,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final selectableFinder = find.byType(SelectableText);
      expect(selectableFinder, findsOneWidget);

      // Simulate a single long press - should work on FIRST attempt
      await tester.longPress(selectableFinder);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // CRITICAL: Selection should activate on first attempt
      expect(firstAttemptWorked, isTrue, 
        reason: 'Selection must work on FIRST long press, not require two attempts');
      expect(selectionChangeCount, greaterThan(0), 
        reason: 'Selection should change on first long press');
    });


  });
}
