import 'package:shared_preferences/shared_preferences.dart';
import 'summary_service.dart';
import 'openai_summary_service.dart';
import 'mistral_summary_service.dart';

/// Service for managing summary configuration and provider selection
/// 
/// Handles:
/// - Storing user's choice of summary provider (OpenAI or Mistral)
/// - Storing API keys (securely)
/// - Creating and managing summary service instances
class SummaryConfigService {
  static const String _providerKey = 'summary_provider';
  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _mistralApiKeyKey = 'mistral_api_key';
  
  static const String _providerOpenAI = 'openai';
  static const String _providerMistral = 'mistral';
  
  final SharedPreferences _prefs;
  OpenAISummaryService? _openAIService;
  MistralSummaryService? _mistralService;
  
  SummaryConfigService(this._prefs);

  /// Get the current summary service based on user configuration
  Future<SummaryService?> getSummaryService() async {
    final provider = _prefs.getString(_providerKey) ?? _providerOpenAI;
    
    switch (provider) {
      case _providerOpenAI:
        return await _getOpenAIService();
        
      case _providerMistral:
        return await _getMistralService();
        
      default:
        // Default to OpenAI if available, otherwise Mistral
        final openAIService = await _getOpenAIService();
        if (openAIService != null) return openAIService;
        return await _getMistralService();
    }
  }

  /// Get OpenAI service instance, creating it if needed
  Future<OpenAISummaryService?> _getOpenAIService() async {
    final apiKey = _prefs.getString(_openaiApiKeyKey);
    if (apiKey == null || apiKey.isEmpty) {
      return null;
    }
    _openAIService ??= OpenAISummaryService(apiKey);
    return _openAIService;
  }

  /// Get Mistral service instance, creating it if needed
  Future<MistralSummaryService?> _getMistralService() async {
    final apiKey = _prefs.getString(_mistralApiKeyKey);
    if (apiKey == null || apiKey.isEmpty) {
      return null;
    }
    _mistralService ??= MistralSummaryService(apiKey);
    return _mistralService;
  }

  /// Set the summary provider (OpenAI or Mistral)
  Future<void> setProvider(String provider) async {
    if (provider != _providerOpenAI && provider != _providerMistral) {
      throw ArgumentError('Invalid provider: $provider');
    }
    await _prefs.setString(_providerKey, provider);
    // Reset service instances to force recreation
    _openAIService = null;
    _mistralService = null;
  }

  /// Get the current provider
  String getProvider() {
    return _prefs.getString(_providerKey) ?? _providerOpenAI;
  }

  /// Set the OpenAI API key
  Future<void> setOpenAIApiKey(String apiKey) async {
    await _prefs.setString(_openaiApiKeyKey, apiKey);
    // Reset OpenAI service instance to force recreation with new key
    _openAIService = null;
  }

  /// Get the OpenAI API key (for display purposes, masked)
  String? getOpenAIApiKey() {
    final key = _prefs.getString(_openaiApiKeyKey);
    if (key == null || key.isEmpty) {
      return null;
    }
    // Return masked version for display
    if (key.length <= 8) {
      return '••••••••';
    }
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  /// Get the raw OpenAI API key (for sync purposes, not masked)
  String? getRawOpenAIApiKey() {
    return _prefs.getString(_openaiApiKeyKey);
  }

  /// Check if OpenAI API key is configured
  bool isOpenAIConfigured() {
    final key = _prefs.getString(_openaiApiKeyKey);
    return key != null && key.isNotEmpty;
  }

  /// Set the Mistral API key
  Future<void> setMistralApiKey(String apiKey) async {
    await _prefs.setString(_mistralApiKeyKey, apiKey);
    // Reset Mistral service instance to force recreation with new key
    _mistralService = null;
  }

  /// Get the Mistral API key (for display purposes, masked)
  String? getMistralApiKey() {
    final key = _prefs.getString(_mistralApiKeyKey);
    if (key == null || key.isEmpty) {
      return null;
    }
    // Return masked version for display
    if (key.length <= 8) {
      return '••••••••';
    }
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  /// Get the raw Mistral API key (for sync purposes, not masked)
  String? getRawMistralApiKey() {
    return _prefs.getString(_mistralApiKeyKey);
  }

  /// Check if Mistral API key is configured
  bool isMistralConfigured() {
    final key = _prefs.getString(_mistralApiKeyKey);
    return key != null && key.isNotEmpty;
  }

  /// Get available providers
  List<String> getAvailableProviders() {
    final providers = <String>[];
    
    if (isOpenAIConfigured()) {
      providers.add(_providerOpenAI);
    }
    
    if (isMistralConfigured()) {
      providers.add(_providerMistral);
    }
    
    return providers;
  }
}



