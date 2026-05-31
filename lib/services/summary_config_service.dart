import 'package:shared_preferences/shared_preferences.dart';
import 'summary_service.dart';
import 'openai_summary_service.dart';
import 'mistral_summary_service.dart';
import 'codex_auth_service.dart';
import 'codex_summary_service.dart';

/// Service for managing summary configuration and provider selection
///
/// Handles:
/// - Storing user's choice of summary provider (OpenAI, Mistral, or ChatGPT/Codex)
/// - Storing API keys (securely)
/// - ChatGPT/Codex OAuth via [CodexAuthService]
/// - Creating and managing summary service instances
class SummaryConfigService {
  static const String providerKey = 'summary_provider';
  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _mistralApiKeyKey = 'mistral_api_key';

  static const String providerOpenAI = 'openai';
  static const String providerMistral = 'mistral';
  static const String providerCodex = CodexSummaryService.providerId;

  final SharedPreferences _prefs;
  final CodexAuthService _codexAuth;
  OpenAISummaryService? _openAIService;
  MistralSummaryService? _mistralService;
  CodexSummaryService? _codexService;

  SummaryConfigService(this._prefs, {CodexAuthService? codexAuth})
      : _codexAuth = codexAuth ?? CodexAuthService();

  /// Get the current summary service based on user configuration
  Future<SummaryService?> getSummaryService() async {
    final provider = _prefs.getString(providerKey) ?? providerOpenAI;

    switch (provider) {
      case providerOpenAI:
        return _getOpenAIService();

      case providerMistral:
        return _getMistralService();

      case providerCodex:
        return _getCodexService();

      default:
        final openAIService = await _getOpenAIService();
        if (openAIService != null) return openAIService;
        final codex = await _getCodexService();
        if (codex != null) return codex;
        return _getMistralService();
    }
  }

  Future<OpenAISummaryService?> _getOpenAIService() async {
    final apiKey = _prefs.getString(_openaiApiKeyKey);
    if (apiKey == null || apiKey.isEmpty) {
      return null;
    }
    _openAIService ??= OpenAISummaryService(apiKey);
    return _openAIService;
  }

  Future<MistralSummaryService?> _getMistralService() async {
    final apiKey = _prefs.getString(_mistralApiKeyKey);
    if (apiKey == null || apiKey.isEmpty) {
      return null;
    }
    _mistralService ??= MistralSummaryService(apiKey);
    return _mistralService;
  }

  Future<CodexSummaryService?> _getCodexService() async {
    if (!await _codexAuth.isConfigured()) {
      return null;
    }
    _codexService ??= CodexSummaryService(authService: _codexAuth);
    return _codexService;
  }

  CodexAuthService get codexAuth => _codexAuth;

  Future<void> setProvider(String provider) async {
    if (provider != providerOpenAI &&
        provider != providerMistral &&
        provider != providerCodex) {
      throw ArgumentError('Invalid provider: $provider');
    }
    await _prefs.setString(providerKey, provider);
    _openAIService = null;
    _mistralService = null;
    _codexService = null;
  }

  String getProvider() {
    return _prefs.getString(providerKey) ?? providerOpenAI;
  }

  Future<void> setOpenAIApiKey(String apiKey) async {
    await _prefs.setString(_openaiApiKeyKey, apiKey);
    _openAIService = null;
  }

  String? getOpenAIApiKey() {
    final key = _prefs.getString(_openaiApiKeyKey);
    if (key == null || key.isEmpty) {
      return null;
    }
    if (key.length <= 8) {
      return '••••••••';
    }
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  String? getRawOpenAIApiKey() {
    return _prefs.getString(_openaiApiKeyKey);
  }

  bool isOpenAIConfigured() {
    final key = _prefs.getString(_openaiApiKeyKey);
    return key != null && key.isNotEmpty;
  }

  Future<void> setMistralApiKey(String apiKey) async {
    await _prefs.setString(_mistralApiKeyKey, apiKey);
    _mistralService = null;
  }

  String? getMistralApiKey() {
    final key = _prefs.getString(_mistralApiKeyKey);
    if (key == null || key.isEmpty) {
      return null;
    }
    if (key.length <= 8) {
      return '••••••••';
    }
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  String? getRawMistralApiKey() {
    return _prefs.getString(_mistralApiKeyKey);
  }

  bool isMistralConfigured() {
    final key = _prefs.getString(_mistralApiKeyKey);
    return key != null && key.isNotEmpty;
  }

  Future<bool> isCodexConfigured() => _codexAuth.isConfigured();

  List<String> getAvailableProviders() {
    final providers = <String>[];

    if (isOpenAIConfigured()) {
      providers.add(providerOpenAI);
    }

    // Codex availability is async; settings screen checks separately.
    if (isMistralConfigured()) {
      providers.add(providerMistral);
    }

    return providers;
  }

  Future<List<String>> getAvailableProvidersAsync() async {
    final providers = getAvailableProviders();
    if (await isCodexConfigured() && !providers.contains(providerCodex)) {
      providers.add(providerCodex);
    }
    return providers;
  }
}
