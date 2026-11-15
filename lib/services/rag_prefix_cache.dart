import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'rag_database_service.dart';
import 'rag_embedding_service_factory.dart';

/// Debounced preparation runs while reading, never during a question.
class RagPrefixCache {
  static final _timers = <String, Timer>{};
  static Future<void> prepare(String bookId, int boundary) async {
    final configured = await RagEmbeddingServiceFactory.create(
      await SharedPreferences.getInstance(),
    );
    if (configured == null) return;
    _timers.remove(bookId)?.cancel();
    if (boundary <= 0) return;
    _timers[bookId] = Timer(const Duration(seconds: 3), () async {
      _timers.remove(bookId);
      try {
        final service = await RagEmbeddingServiceFactory.create(
          await SharedPreferences.getInstance(),
        );
        if (service == null) return;
        final db = RagDatabaseService();
        final status = await db.getActiveIndexStatus(bookId);
        if (status?.embeddingProvider != service.providerName ||
            status?.embeddingModel != service.modelName) {
          return;
        }
        final identity =
            '${service.providerName}:${service.modelName}:${service.embeddingDimensions}:${status?.contentHash}:${status?.configHash}';
        final cached = await db.prefixVectors(bookId, boundary, identity);
        final passages = (await db.crossingPassages(
          bookId,
          boundary,
        )).where((c) => !cached.containsKey(c.chunkId)).toList();
        if (passages.isEmpty) return;
        final vectors = await service.embedTexts(
          passages.map((c) => c.text).toList(),
        );
        for (var i = 0; i < passages.length && i < vectors.length; i++) {
          if (vectors[i].length == service.embeddingDimensions) {
            await db.savePrefixVector(
              bookId,
              boundary,
              identity,
              passages[i].chunkId,
              vectors[i],
            );
          }
        }
      } catch (_) {
        /* Safe lexical prefixes remain available. */
      }
    });
  }
}
