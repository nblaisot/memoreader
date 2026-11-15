import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:memoreader/screens/reader/reader_menu.dart';
import 'package:memoreader/services/book_service.dart';
import 'package:memoreader/services/rag_database_service.dart';
import 'package:memoreader/services/rag_indexing_service.dart';
import 'package:memoreader/services/rag_native_database.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/models/rag_index_progress.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class UnusedBooks extends BookService {
  int calls = 0;
  @override
  Future<List<Book>> getAllBooks() async {
    calls++;
    throw StateError('Menu must not enqueue indexing');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final books = UnusedBooks();
  late RagIndexingService indexer;
  setUpAll(() async {
    databaseFactory = ragDatabaseFactory;
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('rag-ready-')).path,
    );
    indexer = RagIndexingService(bookService: books);
    await RagDatabaseService().saveIndexStatus(
      RagIndexProgress(
        bookId: 'ready',
        status: RagIndexStatus.completed,
        totalChunks: 1,
        indexedChunks: 1,
        lastUpdated: DateTime.now(),
      ),
    );
    await indexer.observe('ready').first;
  });
  tearDownAll(() async => RagDatabaseService().close());
  test('readiness distinguishes unknown from preparation', () {
    expect(readinessOf(null), RagReadiness.unknown);
  });
  test(
    'observation cancels after its first value without queueing work',
    () async {
      await RagDatabaseService().saveIndexStatus(
        RagIndexProgress(
          bookId: 'ready',
          status: RagIndexStatus.completed,
          totalChunks: 1,
          indexedChunks: 1,
          lastUpdated: DateTime.now(),
        ),
      );
      final result = await indexer
          .observe('ready')
          .first
          .timeout(const Duration(seconds: 2));
      expect(result.isComplete, true);
      expect(books.calls, 0);
    },
  );
  testWidgets(
    'repeated reader menu openings do not start indexing or flash progress',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReaderMenu(
                  context: context,
                  fontScale: 1,
                  onFontScaleChanged: (_) {},
                  hasChapters: false,
                  hasSavedWords: false,
                  bookId: 'ready',
                ),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Open menu'));
        await tester.runAsync(() async {
          await RagDatabaseService().getActiveIndexStatus('ready');
          await RagDatabaseService().getIndexStatus('ready');
        });
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(indexer.isIndexing('ready'), false);
        expect(books.calls, 0);
        Navigator.of(
          tester.element(find.byType(SingleChildScrollView).last),
        ).pop();
        await tester.runAsync(() async {
          await RagDatabaseService().getIndexStatus('ready');
        });
        await tester.pumpAndSettle();
      }
    },
  );
}
