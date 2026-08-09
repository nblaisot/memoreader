/// OpenAI Codex / ChatGPT OAuth constants (same flow as Codex CLI).
class CodexAuthConstants {
  CodexAuthConstants._();

  static const String clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const String issuer = 'https://auth.openai.com';
  static const String tokenUrl = '$issuer/oauth/token';
  static const String accountsApiBase = '$issuer/api/accounts';
  static const String deviceVerificationUrl = '$issuer/codex/device';
  static const String deviceRedirectUri = '$issuer/deviceauth/callback';
  static const String scope = 'openid profile email offline_access';

  static const String codexResponsesUrl =
      'https://chatgpt.com/backend-api/codex/responses';

  /// OpenAI embeddings endpoint (Codex OAuth bearer token).
  static const String codexEmbeddingsUrl =
      'https://api.openai.com/v1/embeddings';

  /// Default model for Codex backend (ChatGPT subscription).
  static const String defaultModel = 'gpt-5.6-terra';

  /// Embedding model compatible with existing OpenAI-indexed books.
  static const String defaultEmbeddingModel = 'text-embedding-3-small';

  static const String jwtAuthClaimPath = 'https://api.openai.com/auth';

  static const Duration deviceLoginTimeout = Duration(minutes: 15);
  static const Duration refreshSkew = Duration(seconds: 30);
}
