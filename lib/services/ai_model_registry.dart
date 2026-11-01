/// Central, versioned model declarations used by MemoReader.
///
/// Keep provider capabilities here instead of scattering model IDs and limits
/// across request services. Embedding identity is part of the persisted index
/// contract and must never change without rebuilding that index.
class AiModelRegistry {
  AiModelRegistry._();

  static const int registryVersion = 2;
  static const String lastVerified = '2026-11-01';

  static const openAiEmbedding = EmbeddingModelSpec(
    providerId: 'openai',
    modelId: 'text-embedding-3-small',
    dimensions: 1536,
    maxInputTokens: 8192,
  );

  static const mistralEmbedding = EmbeddingModelSpec(
    providerId: 'mistral',
    modelId: 'mistral-embed',
    dimensions: 1024,
    maxInputTokens: 8192,
  );

  static const openAiAnswer = GenerationModelSpec(
    providerId: 'openai',
    modelId: 'gpt-6.1-sol',
    endpoint: 'https://api.openai.com/v1/responses',
    maxOutputTokens: 4000,
    reasoningEffort: 'low',
  );

  static const openAiPlanner = GenerationModelSpec(
    providerId: 'openai',
    modelId: 'gpt-6-luna',
    endpoint: 'https://api.openai.com/v1/responses',
    maxOutputTokens: 800,
    reasoningEffort: 'low',
  );

  static const mistralAnswer = GenerationModelSpec(
    providerId: 'mistral',
    modelId: 'mistral-large-4',
    endpoint: 'https://api.mistral.ai/v1/chat/completions',
    maxOutputTokens: 4000,
  );

  static const mistralPlanner = GenerationModelSpec(
    providerId: 'mistral',
    modelId: 'mistral-small-2603',
    endpoint: 'https://api.mistral.ai/v1/chat/completions',
    maxOutputTokens: 800,
    reasoningEffort: 'none',
  );
}

class EmbeddingModelSpec {
  const EmbeddingModelSpec({
    required this.providerId,
    required this.modelId,
    required this.dimensions,
    required this.maxInputTokens,
  });

  final String providerId;
  final String modelId;
  final int dimensions;
  final int maxInputTokens;

  String get identity => '$providerId:$modelId:$dimensions';
}

class GenerationModelSpec {
  const GenerationModelSpec({
    required this.providerId,
    required this.modelId,
    required this.endpoint,
    required this.maxOutputTokens,
    this.reasoningEffort,
  });

  final String providerId;
  final String modelId;
  final String endpoint;
  final int maxOutputTokens;
  final String? reasoningEffort;
}
