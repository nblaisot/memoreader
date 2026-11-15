import 'http_embedding_service.dart';
import 'ai_model_registry.dart';
export 'rag_embedding_service.dart' show EmbeddingRateLimitException;

class MistralEmbeddingService extends ScheduledHttpEmbeddingService {
  MistralEmbeddingService(
    super.apiKey, {
    String? model,
    super.client,
    super.throttleStore,
    super.now,
    super.sleep,
    super.random,
  }) : super(model: model ?? 'mistral-embed');
  @override
  String get providerName => 'Mistral AI';
  @override
  String get endpoint => 'https://api.mistral.ai/v1/embeddings';
  @override
  int get embeddingDimensions => 1024;
  @override
  int get maxTokensPerInput => AiModelRegistry.mistralEmbedding.maxInputTokens;
  @override
  int get maxBatchInputs => 100;
}
