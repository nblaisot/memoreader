import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/models/reading_progress.dart';
import 'package:memoreader/services/api_cache_service.dart';
import 'package:memoreader/services/enhanced_summary_service.dart';
import 'package:memoreader/services/summary_service.dart';
import 'package:memoreader/services/summary_database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingSummaryService implements SummaryService {
  final List<String> prompts = [];

  @override
  String get serviceName => 'recording';

  @override
  Future<String> generateSummary(
    String prompt,
    String languageCode, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    prompts.add(prompt);
    return 'summary-${prompts.length}';
  }

  @override
  Future<bool> isAvailable() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SummaryDatabaseService().clearAll();
    await ApiCacheService().clearAllCache();
  });

  test('last chunk summary uses text ending at last visible word', () async {
    final prefs = await SharedPreferences.getInstance();
    final recordingService = _RecordingSummaryService();
    final enhancedService = EnhancedSummaryService(recordingService, prefs);

    const text = 'This is the visible text ending with finale';
    final book = Book(
      id: 'book-1',
      title: 'Test Book',
      author: 'Tester',
      filePath: '/tmp/book.epub',
      dateAdded: DateTime.now(),
    );
    final progress = ReadingProgress(
      bookId: book.id,
      lastRead: DateTime.now(),
      progress: 0.5,
      currentCharacterIndex: text.length,
      lastVisibleCharacterIndex: text.length,
    );

    await enhancedService.getSummaryUpToPosition(
      book,
      progress,
      'en',
      preparedEngineText: text,
    );

    final chunkPrompt = recordingService.prompts.lastWhere(
      (prompt) => prompt.contains('Text to summarize:'),
    );
    final promptSegments = chunkPrompt.split('Text to summarize:');
    expect(promptSegments.length > 1, true);
    final textSection = promptSegments[1].split('Detailed summary:').first.trim();

    expect(textSection.endsWith('finale'), isTrue);
  });
}
