import 'package:shared_preferences/shared_preferences.dart';

import 'mistral_embedding_service.dart';
import 'openai_embedding_service.dart';
import 'rag_embedding_service.dart';

/// Configuration for the semantic-index provider.
///
/// This is deliberately independent from the answer/summary provider. A
/// ChatGPT subscription is not an OpenAI Platform embedding credential.
class EmbeddingConfigService {
  EmbeddingConfigService(this._prefs);

  static const String providerKey = 'rag_embedding_provider';
  static const String providerOpenAI = 'openai';
  static const String providerMistral = 'mistral';

  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _mistralApiKeyKey = 'mistral_api_key';

  final SharedPreferences _prefs;

  String? getProvider() {
    final configured = _prefs.getString(providerKey);
    if (configured == providerOpenAI && isOpenAIConfigured()) {
      return configured;
    }
    if (configured == providerMistral && isMistralConfigured()) {
      return configured;
    }

    // Safe migration for installations created before embedding and answer
    // providers were separated. Prefer OpenAI only when its Platform key is
    // present; ChatGPT/Codex authentication is intentionally ignored.
    if (isOpenAIConfigured()) return providerOpenAI;
    if (isMistralConfigured()) return providerMistral;
    return null;
  }

  Future<void> setProvider(String provider) async {
    if (provider != providerOpenAI && provider != providerMistral) {
      throw ArgumentError('Invalid embedding provider: $provider');
    }
    if (provider == providerOpenAI && !isOpenAIConfigured()) {
      throw StateError(
        'An OpenAI Platform API key is required for embeddings.',
      );
    }
    if (provider == providerMistral && !isMistralConfigured()) {
      throw StateError('A Mistral API key is required for embeddings.');
    }
    await _prefs.setString(providerKey, provider);
  }

  bool isOpenAIConfigured() =>
      (_prefs.getString(_openaiApiKeyKey) ?? '').isNotEmpty;

  bool isMistralConfigured() =>
      (_prefs.getString(_mistralApiKeyKey) ?? '').isNotEmpty;

  EmbeddingService? createService() {
    switch (getProvider()) {
      case providerOpenAI:
        return OpenAIEmbeddingService(_prefs.getString(_openaiApiKeyKey)!);
      case providerMistral:
        return MistralEmbeddingService(_prefs.getString(_mistralApiKeyKey)!);
      default:
        return null;
    }
  }

  String unavailableMessage() {
    return 'RAG indexing needs an OpenAI Platform or Mistral API key. '
        'A ChatGPT/Codex sign-in can be used for answers but does not provide '
        'OpenAI Platform embeddings.';
  }
}
