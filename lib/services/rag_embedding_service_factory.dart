import 'package:shared_preferences/shared_preferences.dart';
import 'summary_config_service.dart';
import 'rag_embedding_service.dart';
import 'openai_embedding_service.dart';
import 'mistral_embedding_service.dart';
import 'codex_auth_service.dart';
import 'codex_embedding_service.dart';

/// Thrown when Codex is selected but no embedding source is available.
class CodexEmbeddingUnavailableException implements Exception {
  CodexEmbeddingUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Factory for creating embedding services based on configuration
class RagEmbeddingServiceFactory {
  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _mistralApiKeyKey = 'mistral_api_key';

  /// Create embedding service based on configured provider.
  ///
  /// When [SummaryConfigService.providerCodex] is selected, prefer
  /// [CodexEmbeddingService] when ChatGPT is signed in; otherwise fall back
  /// to OpenAI or Mistral API keys if configured.
  static Future<EmbeddingService?> create(
    SharedPreferences prefs, {
    SummaryConfigService? configService,
  }) async {
    final config = configService ?? SummaryConfigService(prefs);
    final provider = config.getProvider();

    if (provider == SummaryConfigService.providerCodex) {
      return _embeddingForCodexProvider(prefs, config);
    }

    if (provider == SummaryConfigService.providerOpenAI) {
      final apiKey = prefs.getString(_openaiApiKeyKey);
      if (apiKey == null || apiKey.isEmpty) {
        return null;
      }
      return OpenAIEmbeddingService(apiKey);
    } else if (provider == SummaryConfigService.providerMistral) {
      final apiKey = prefs.getString(_mistralApiKeyKey);
      if (apiKey == null || apiKey.isEmpty) {
        return null;
      }
      return MistralEmbeddingService(apiKey);
    }

    return null;
  }

  static Future<EmbeddingService?> _embeddingForCodexProvider(
    SharedPreferences prefs,
    SummaryConfigService configService,
  ) async {
    final auth = configService.codexAuth;
    if (await auth.isConfigured()) {
      return CodexEmbeddingService(authService: auth);
    }

    final openaiKey = prefs.getString(_openaiApiKeyKey);
    if (openaiKey != null && openaiKey.isNotEmpty) {
      return OpenAIEmbeddingService(openaiKey);
    }
    final mistralKey = prefs.getString(_mistralApiKeyKey);
    if (mistralKey != null && mistralKey.isNotEmpty) {
      return MistralEmbeddingService(mistralKey);
    }
    return null;
  }

  static Future<String> unavailableMessage(
    SharedPreferences prefs, {
    SummaryConfigService? configService,
  }) async {
    final config = configService ?? SummaryConfigService(prefs);
    if (config.getProvider() == SummaryConfigService.providerCodex) {
      final signedIn = await config.isCodexConfigured();
      if (signedIn) {
        return 'ChatGPT/Codex embeddings are unavailable. '
            'Try signing in again, or add an OpenAI or Mistral API key as fallback.';
      }
      return 'Sign in with ChatGPT/Codex for summaries and embeddings, '
          'or add an OpenAI or Mistral API key below for RAG only.';
    }
    return 'Embedding service not available. Please configure an API key.';
  }
}
