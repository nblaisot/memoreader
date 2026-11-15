import 'http_embedding_service.dart';
import 'ai_model_registry.dart';
export 'rag_embedding_service.dart' show EmbeddingRateLimitException;

class OpenAIEmbeddingService extends ScheduledHttpEmbeddingService {
  OpenAIEmbeddingService(
    super.apiKey, {
    String? model,
    super.client,
    super.throttleStore,
    super.now,
    super.sleep,
    super.random,
  }) : super(model: model ?? 'text-embedding-3-small');
  @override
  String get providerName => 'OpenAI';
  @override
  String get endpoint => 'https://api.openai.com/v1/embeddings';
  @override
  int get embeddingDimensions =>
      model == 'text-embedding-3-large' ? 3072 : 1536;
  @override
  int get maxTokensPerInput => AiModelRegistry.openAiEmbedding.maxInputTokens;
}
