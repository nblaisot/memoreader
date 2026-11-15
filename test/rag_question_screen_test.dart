import 'dart:io';
import 'package:memoreader/services/rag_native_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:memoreader/screens/rag_question_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = ragDatabaseFactory;
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('rag-widget-')).path,
    );
  });
  testWidgets('question chat defaults to already read', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RagQuestionScreen(books: [], bookReadPositions: {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('question composer stays above the keyboard', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const keyboardHeightInPhysicalPixels = 900.0;
    tester.view.viewInsets = const FakeViewPadding(
      bottom: keyboardHeightInPhysicalPixels,
    );
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RagQuestionScreen(books: [], bookReadPositions: {}),
      ),
    );
    await tester.pumpAndSettle();

    final keyboardTop =
        (tester.view.physicalSize.height - keyboardHeightInPhysicalPixels) /
        tester.view.devicePixelRatio;
    expect(
      tester.getBottomLeft(find.byType(TextField)).dy,
      lessThanOrEqualTo(keyboardTop),
    );
    expect(
      tester.getBottomLeft(find.byType(ElevatedButton)).dy,
      lessThanOrEqualTo(keyboardTop),
    );

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(find.byType(TextField)).dy,
      greaterThan(keyboardTop),
    );
  });
}
