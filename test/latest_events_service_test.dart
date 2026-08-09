import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/services/latest_events_service.dart';
import 'package:memoreader/services/rag_database_service.dart';
import 'package:memoreader/services/summary_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CapturingSummaryService implements SummaryService {
  String? prompt;
  @override
  Future<String> generateSummary(
    String text,
    String language, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    prompt = text;
    return 'summary';
  }

  @override
  Future<bool> isAvailable() async => true;
  @override
  String get serviceName => 'fake';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await RagDatabaseService().close();
    final file = File(p.join(await getDatabasesPath(), 'rag.db'));
    if (file.existsSync()) file.deleteSync();
  });
  tearDown(() async {
    await RagDatabaseService().clearAll();
    await RagDatabaseService().close();
  });

  test(
    'latest-events prompt ends at the exact last-visible boundary',
    () async {
      final chunk = RagChunk(
        chunkId: 'crossing',
        bookId: 'book',
        text: 'visible FUTURE',
        embedding: Float32List.fromList([1]),
        embeddingDimension: 1,
        charStart: 0,
        charEnd: 14,
        tokenStart: 0,
        tokenEnd: 2,
        createdAt: DateTime.utc(2026),
      );
      await RagDatabaseService().saveChunk(chunk);
      final summary = _CapturingSummaryService();

      await LatestEventsService().generateLatestEventsSummary(
        bookId: 'book',
        currentCharPosition: 7,
        summaryService: summary,
        language: 'en',
      );

      expect(summary.prompt, contains('visible'));
      expect(summary.prompt, isNot(contains('FUTURE')));
    },
  );
}
