import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/screens/reader/reader_menu.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
    'reading options menu uses SingleChildScrollView on short viewport',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showReaderMenu(
                    context: context,
                    fontScale: 1.0,
                    onFontScaleChanged: (_) {},
                    hasChapters: true,
                    hasSavedWords: false,
                    bookId: 'test-book-scroll',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(SingleChildScrollView), findsOneWidget);
    },
  );
}
