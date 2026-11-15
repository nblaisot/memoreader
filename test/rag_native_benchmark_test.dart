import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/services/rag_database_service.dart';
import 'package:memoreader/services/rag_native_database.dart';
import 'package:memoreader/services/rag_hybrid_retriever.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '1/20/100-book exact-search benchmark and Dart baseline',
    () async {
      databaseFactory = ragDatabaseFactory;
      await databaseFactory.setDatabasesPath(
        (await Directory.systemTemp.createTemp('rag-benchmark-')).path,
      );
      final db = RagDatabaseService();
      const passagesPerBook = int.fromEnvironment(
        'RAG_PASSAGES_PER_BOOK',
        defaultValue: 300,
      );
      final report = <Map<String, Object?>>[];
      for (final count in [1, 20, 100]) {
        await db.clearAll();
        final indexing = Stopwatch()..start();
        for (var book = 0; book < count; book++) {
          final chunks = <RagChunk>[];
          for (var i = 0; i < passagesPerBook; i++) {
            final vector = Float32List(1536)
              ..[(book * passagesPerBook + i) % 1536] = 1;
            final text =
                'Book $book passage $i. The quasar valve has a violet spring. ${'Narrative context. ' * 80}';
            chunks.add(
              RagChunk(
                chunkId: 'b$book-p$i',
                bookId: 'b$book',
                text: text,
                embedding: vector,
                embeddingDimension: 1536,
                sectionIndex: i,
                charStart: i * 2000,
                charEnd: i * 2000 + text.length,
                tokenStart: 0,
                tokenEnd: 400,
                createdAt: DateTime.utc(2026),
              ),
            );
          }
          await db.saveChunks(chunks);
        }
        indexing.stop();
        await db.close();
        final scope = [for (var b = 0; b < count; b++) 'b$b'];
        final query = Float32List(1536)..[0] = 1;
        final samples = <int>[];
        final rss = ProcessInfo.currentRss;
        var first = 0;
        for (var sample = 0; sample < 12; sample++) {
          final watch = Stopwatch()..start();
          final results = await Future.wait([
            db.searchSemantic(vector: query, bookIds: scope, limit: 40),
            db.searchLexical(matchQuery: '"quasar"', bookIds: scope, limit: 40),
          ]);
          expect(results.first.first.score, closeTo(1, 0.00001));
          if (sample == 0) {
            first = watch.elapsedMilliseconds;
          } else {
            samples.add(watch.elapsedMilliseconds);
          }
        }
        samples.sort();
        final rssAfterNative = ProcessInfo.currentRss;
        final peakAfterNative = ProcessInfo.maxRss;
        final baseline = Stopwatch()..start();
        final corpus = <RagChunk>[];
        for (final book in scope) {
          corpus.addAll(await db.getChunks(book));
        }
        final ranked =
            corpus
                .map(
                  (c) => (
                    c.chunkId,
                    RagHybridRetriever.cosineSimilarity(c.embedding, query),
                  ),
                )
                .toList()
              ..sort((a, b) => b.$2.compareTo(a.$2));
        expect(ranked.first.$2, closeTo(1, 0.00001));
        report.add({
          'books': count,
          'chunks': count * passagesPerBook,
          'dimensions': 1536,
          'firstQueryMs': first,
          'warmP50Ms': samples[samples.length ~/ 2],
          'warmP95Ms':
              samples[(samples.length * .95).floor().clamp(
                0,
                samples.length - 1,
              )],
          'indexMs': indexing.elapsedMilliseconds,
          'legacyLoadAndDartScanMs': baseline.elapsedMilliseconds,
          'rssBeforeNative': rss,
          'rssAfterNative': rssAfterNative,
          'peakRssAfterNative': peakAfterNative,
          'rssAfterBaseline': ProcessInfo.currentRss,
          'peakRssAfterBaseline': ProcessInfo.maxRss,
          'platform': Platform.operatingSystem,
        });
      }
      await Directory('build/rag_eval').create(recursive: true);
      await File(
        'build/rag_eval/native-benchmark.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      await db.close();
    },
    skip: !const bool.fromEnvironment('RAG_BENCHMARK'),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
