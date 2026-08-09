import 'package:shared_preferences/shared_preferences.dart';
import 'rag_embedding_service.dart';
import 'embedding_config_service.dart';

/// Factory for creating embedding services based on configuration
class RagEmbeddingServiceFactory {
  /// Create the explicitly configured embedding service. Summary/Codex
  /// selection is intentionally irrelevant here.
  static Future<EmbeddingService?> create(
    SharedPreferences prefs, {
    EmbeddingConfigService? configService,
  }) async {
    return (configService ?? EmbeddingConfigService(prefs)).createService();
  }

  static Future<String> unavailableMessage(
    SharedPreferences prefs, {
    EmbeddingConfigService? configService,
  }) async {
    return (configService ?? EmbeddingConfigService(prefs))
        .unavailableMessage();
  }
}
