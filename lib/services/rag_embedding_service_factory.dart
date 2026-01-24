import 'package:shared_preferences/shared_preferences.dart';
import 'summary_config_service.dart';
import 'rag_embedding_service.dart';
import 'openai_embedding_service.dart';
import 'mistral_embedding_service.dart';

/// Factory for creating embedding services based on configuration
class RagEmbeddingServiceFactory {
  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _mistralApiKeyKey = 'mistral_api_key';

  /// Create embedding service based on configured provider
  static Future<EmbeddingService?> create(SharedPreferences prefs) async {
    final configService = SummaryConfigService(prefs);
    final provider = configService.getProvider();

    if (provider == 'openai') {
      // Get actual API key directly from SharedPreferences (not masked)
      final apiKey = prefs.getString(_openaiApiKeyKey);
      if (apiKey == null || apiKey.isEmpty) {
        return null;
      }
      return OpenAIEmbeddingService(apiKey);
    } else if (provider == 'mistral') {
      // Get actual API key directly from SharedPreferences (not masked)
      final apiKey = prefs.getString(_mistralApiKeyKey);
      if (apiKey == null || apiKey.isEmpty) {
        return null;
      }
      return MistralEmbeddingService(apiKey);
    }

    return null;
  }
}
