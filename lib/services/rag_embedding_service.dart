import 'dart:typed_data';

/// Exception thrown when embedding API rate limit is exceeded
class EmbeddingRateLimitException implements Exception {
  final String message;
  
  /// Number of seconds to wait before retrying (from API Retry-After header)
  final int? retryAfterSeconds;

  EmbeddingRateLimitException(this.message, {this.retryAfterSeconds});

  @override
  String toString() {
    if (retryAfterSeconds != null) {
      return 'EmbeddingRateLimitException: $message (retry after ${retryAfterSeconds}s)';
    }
    return 'EmbeddingRateLimitException: $message';
  }
}

/// Abstract interface for embedding services
abstract class EmbeddingService {
  /// Generate embedding for a single text
  Future<Float32List> embedText(String text);

  /// Generate embeddings for multiple texts (batch)
  Future<List<Float32List>> embedTexts(List<String> texts);

  /// Get the embedding dimension (e.g., 1536, 1024)
  int get embeddingDimensions;

  /// Get the provider name (e.g., 'OpenAI', 'Mistral')
  String get providerName;

  /// Get the model name (e.g., 'text-embedding-3-small', 'mistral-embed')
  String get modelName;

  /// Maximum number of tokens allowed per input for this model.
  ///
  /// This should reflect the provider's documented context window for the
  /// configured [modelName]. For example, OpenAI's `text-embedding-3-small`
  /// currently supports up to 8192 tokens per input.
  int get maxTokensPerInput;

  /// Check if the service is available (API key configured)
  Future<bool> isAvailable();
}
