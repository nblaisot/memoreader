import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../services/settings_service.dart';
import '../services/summary_service.dart';
import '../services/api_cost_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settingsService = SettingsService();
  final SummaryService _summaryService = SummaryService();
  final ApiCostService _costService = ApiCostService();
  String? _selectedLanguageCode;
  final TextEditingController _apiKeyController = TextEditingController();
  double _totalCost = 0.0;

  @override
  void initState() {
    super.initState();
    _loadLanguagePreference();
    _loadApiKey();
    _loadCost();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload cost when screen becomes visible
    _loadCost();
  }

  Future<void> _loadCost() async {
    final cost = await _costService.getTotalCost();
    if (mounted) {
      setState(() {
        _totalCost = cost;
      });
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final apiKey = prefs.getString('openai_api_key');
      if (apiKey != null && mounted) {
        _apiKeyController.text = apiKey;
      }
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _saveApiKey() async {
    final apiKey = _apiKeyController.text.trim();
    await _summaryService.setApiKey(apiKey);
    
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.apiKeySaved),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadLanguagePreference() async {
    final languageCode = await _settingsService.getLanguageCode();
    
    setState(() {
      _selectedLanguageCode = languageCode;
    });
  }

  Future<void> _saveLanguagePreference(String? languageCode) async {
    await _settingsService.saveLanguage(languageCode);
    
    setState(() {
      _selectedLanguageCode = languageCode;
    });
    
    // Update app locale immediately
    final appState = MyApp.of(context);
    if (languageCode != null) {
      appState.setLocale(Locale(languageCode));
    } else {
      appState.setLocale(WidgetsBinding.instance.platformDispatcher.locale);
    }
    
    // Show message that app needs to restart for full effect
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.languageChangedRestart),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          // Language section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.language,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.languageDescription,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                ),
                const SizedBox(height: 16),
                // Language options
                RadioListTile<String?>(
                  title: Text(l10n.languageSystemDefault),
                  subtitle: Text(l10n.languageSystemDefaultDescription),
                  value: null,
                  groupValue: _selectedLanguageCode,
                  onChanged: (value) => _saveLanguagePreference(value),
                ),
                RadioListTile<String?>(
                  title: const Text('English'),
                  value: 'en',
                  groupValue: _selectedLanguageCode,
                  onChanged: (value) => _saveLanguagePreference(value),
                ),
                RadioListTile<String?>(
                  title: const Text('Français'),
                  value: 'fr',
                  groupValue: _selectedLanguageCode,
                  onChanged: (value) => _saveLanguagePreference(value),
                ),
              ],
            ),
          ),
          // OpenAI API Key section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.openaiApiKey,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.openaiApiKeyDescription,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _apiKeyController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.openaiApiKey,
                    hintText: 'sk-...',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.visibility),
                      onPressed: () {
                        // Toggle visibility (simplified - in production use a proper toggle)
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _showApiKeyInfoDialog(context),
                  child: Text(
                    l10n.whatIsApiKey,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // API Cost Display
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.grey[300]!,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            l10n.apiCostLabel,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            '\$${_totalCost.toStringAsFixed(4)}',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.apiCostDescription,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                              fontSize: 11,
                            ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _resetCost,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(l10n.resetApiCost),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _saveApiKey,
                  icon: const Icon(Icons.save),
                  label: Text(l10n.save),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showApiKeyInfoDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.whatIsApiKey),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.apiKeyExplanation),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () async {
                  final uri = Uri.parse('https://platform.openai.com/api-keys');
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(l10n.getApiKeyFromOpenAI),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.apiKeyCostInfo,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[700],
                    ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _resetCost() async {
    await _costService.resetCost();
    await _loadCost();
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.apiCostReset),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

