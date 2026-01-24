import 'rag_embedding_service.dart';

/// Provider-specific configuration for embedding services
class EmbeddingProviderConfig {
  final int maxTokensPerInput;
  final int safetyMarginTokens;
  final int recommendedChunkSize;
  final int maxBatchSize;

  const EmbeddingProviderConfig({
    required this.maxTokensPerInput,
    required this.safetyMarginTokens,
    required this.recommendedChunkSize,
    required this.maxBatchSize,
  });

  /// OpenAI embedding configuration
  /// Based on text-embedding-3-small and text-embedding-3-large
  static const openai = EmbeddingProviderConfig(
    maxTokensPerInput: 8192,
    safetyMarginTokens: 100, // Reduced from typical 256 for efficiency
    recommendedChunkSize: 1000,
    maxBatchSize: 100,
  );

  /// Mistral AI embedding configuration
  /// Based on mistral-embed model
  static const mistral = EmbeddingProviderConfig(
    maxTokensPerInput: 8192,
    safetyMarginTokens: 100,
    recommendedChunkSize: 1000,
    maxBatchSize: 100,
  );

  /// Get configuration for a specific embedding service
  static EmbeddingProviderConfig forService(EmbeddingService service) {
    final providerName = service.providerName.toLowerCase();
    
    if (providerName.contains('openai')) {
      return openai;
    } else if (providerName.contains('mistral')) {
      return mistral;
    }
    
    // Default/fallback configuration
    return const EmbeddingProviderConfig(
      maxTokensPerInput: 8192,
      safetyMarginTokens: 256,
      recommendedChunkSize: 500,
      maxBatchSize: 50,
    );
  }

  /// Calculate effective max tokens with safety margin applied
  int get effectiveMaxTokens => maxTokensPerInput - safetyMarginTokens;
}
