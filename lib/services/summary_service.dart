/// Abstract service for generating book summaries
///
/// This interface allows for different implementations:
/// - OpenAISummaryService: Uses OpenAI API
/// - MistralSummaryService: Uses Mistral AI API
abstract class SummaryService {
  /// Generate a summary for the given text content
  ///
  /// [text] - The text content to summarize
  /// [language] - The language code ('fr' or 'en')
  /// [bookId] - Optional book ID for caching purposes
  /// [onCacheHit] - Optional callback called when response is retrieved from cache
  /// Returns the generated summary
  Future<String> generateSummary(
    String text,
    String language, {
    String? bookId,
    void Function()? onCacheHit,
  });

  /// Check if the service is available and ready to use
  Future<bool> isAvailable();

  /// Get the name of the service for display purposes
  String get serviceName;
}
