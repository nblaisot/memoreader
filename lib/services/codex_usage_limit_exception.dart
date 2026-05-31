/// Thrown when ChatGPT/Codex returns HTTP 429 (subscription usage cap).
class CodexUsageLimitException implements Exception {
  CodexUsageLimitException(
    this.message, {
    this.resetsInSeconds,
    this.planType,
  });

  final String message;
  final int? resetsInSeconds;
  final String? planType;

  @override
  String toString() => message;
}
