import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/summary_config_service.dart';
import '../services/settings_service.dart';
import '../services/prompt_config_service.dart';
import '../main.dart';

/// Settings screen for configuring summary provider, API keys, and prompts
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _PromptFieldConfig {
  const _PromptFieldConfig(this.key, this.label, {this.isLabelField = false});

  final String key;
  final String label;
  final bool isLabelField;
}

class _PromptSection {
  const _PromptSection({
    required this.stateKey,
    required this.title,
    required this.fields,
    this.descriptionBuilder,
    this.crossAxisAlignment,
  });

  final String stateKey;
  final String title;
  final List<_PromptFieldConfig> fields;
  final WidgetBuilder? descriptionBuilder;
  final CrossAxisAlignment? crossAxisAlignment;
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SummaryConfigService _configService;
  late PromptConfigService _promptConfigService;
  final SettingsService _settingsService = SettingsService();
  String _selectedProvider = 'openai';
  String? _selectedLanguageCode;
  bool _isLoading = true;
  bool _isOpenAIConfigured = false;
  bool _isMistralConfigured = false;
  final TextEditingController _openaiApiKeyController = TextEditingController();
  final TextEditingController _mistralApiKeyController = TextEditingController();
  bool _showOpenaiApiKey = false;
  bool _showMistralApiKey = false;
  final Map<String, bool> _expansionState = {
    'chunkSummary': false,
    'characterExtraction': false,
    'batchSummary': false,
    'narrativeSynthesis': false,
    'textAction': false,
  };
  
  // Prompt controllers
  final Map<String, TextEditingController> _promptControllers = {};
  final Map<String, FocusNode> _promptFocusNodes = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _openaiApiKeyController.dispose();
    _mistralApiKeyController.dispose();
    for (final controller in _promptControllers.values) {
      controller.dispose();
    }
    for (final focusNode in _promptFocusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      _configService = SummaryConfigService(prefs);
      _promptConfigService = PromptConfigService(prefs);
      
      _selectedProvider = _configService.getProvider();
      _isOpenAIConfigured = _configService.isOpenAIConfigured();
      _isMistralConfigured = _configService.isMistralConfigured();
      
      // Load masked API keys for display
      final maskedOpenAIKey = _configService.getOpenAIApiKey();
      if (maskedOpenAIKey != null) {
        _openaiApiKeyController.text = maskedOpenAIKey;
      }
      
      final maskedMistralKey = _configService.getMistralApiKey();
      if (maskedMistralKey != null) {
        _mistralApiKeyController.text = maskedMistralKey;
      }
      
      // Load language preference
      _selectedLanguageCode = await _settingsService.getLanguageCode();
      
      // Initialize prompt controllers and focus nodes
      _initializePromptControllers();
    } catch (e) {
      debugPrint('Error loading settings: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _initializePromptControllers() {
    // Initialize controllers for all prompts
    final promptKeys = [
      'chunkSummary_fr',
      'chunkSummary_en',
      'characterExtraction_fr',
      'characterExtraction_en',
      'batchSummary_fr',
      'batchSummary_en',
      'narrativeSynthesis_fr',
      'narrativeSynthesis_en',
      'textActionLabel_fr',
      'textActionLabel_en',
      'textActionPrompt_fr',
      'textActionPrompt_en',
    ];
    
    for (final key in promptKeys) {
      final parts = key.split('_');
      final promptType = parts[0];
      final language = parts[1];
      
      String promptText;
      switch (promptType) {
        case 'chunkSummary':
          promptText = _promptConfigService.getChunkSummaryPrompt(language);
          break;
        case 'characterExtraction':
          promptText = _promptConfigService.getCharacterExtractionPrompt(language);
          break;
        case 'batchSummary':
          promptText = _promptConfigService.getBatchSummaryPrompt(language);
          break;
        case 'narrativeSynthesis':
          promptText = _promptConfigService.getNarrativeSynthesisPrompt(language);
          break;
        case 'textActionLabel':
          promptText = _promptConfigService.getTextActionLabel(language);
          break;
        case 'textActionPrompt':
          promptText = _promptConfigService.getTextActionPrompt(language);
          break;
        default:
          promptText = '';
      }
      
      _promptControllers[key] = TextEditingController(text: promptText);
      _promptFocusNodes[key] = FocusNode();
      
      // Save prompt when focus is lost
      _promptFocusNodes[key]!.addListener(() {
        if (!_promptFocusNodes[key]!.hasFocus) {
          _savePrompt(key);
        }
      });
    }
  }

  Future<void> _savePrompt(String key) async {
    final controller = _promptControllers[key];
    if (controller == null) return;
    
    final parts = key.split('_');
    final promptType = parts[0];
    final language = parts[1];
    
    try {
      switch (promptType) {
        case 'chunkSummary':
          await _promptConfigService.setChunkSummaryPrompt(language, controller.text);
          break;
        case 'characterExtraction':
          await _promptConfigService.setCharacterExtractionPrompt(language, controller.text);
          break;
        case 'batchSummary':
          await _promptConfigService.setBatchSummaryPrompt(language, controller.text);
          break;
        case 'narrativeSynthesis':
          await _promptConfigService.setNarrativeSynthesisPrompt(language, controller.text);
          break;
        case 'textActionLabel':
          await _promptConfigService.setTextActionLabel(language, controller.text);
          break;
        case 'textActionPrompt':
          await _promptConfigService.setTextActionPrompt(language, controller.text);
          break;
      }
      
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.promptSaved),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error saving prompt: $e');
    }
  }

  Future<void> _resetPrompts() async {
    try {
      await _promptConfigService.resetAllPrompts();
      
      // Reload prompt controllers
      for (final key in _promptControllers.keys) {
        final parts = key.split('_');
        final promptType = parts[0];
        final language = parts[1];
        
        String promptText;
        switch (promptType) {
          case 'chunkSummary':
            promptText = _promptConfigService.getChunkSummaryPrompt(language);
            break;
          case 'characterExtraction':
            promptText = _promptConfigService.getCharacterExtractionPrompt(language);
            break;
          case 'batchSummary':
            promptText = _promptConfigService.getBatchSummaryPrompt(language);
            break;
          case 'narrativeSynthesis':
            promptText = _promptConfigService.getNarrativeSynthesisPrompt(language);
            break;
          case 'textActionLabel':
            promptText = _promptConfigService.getTextActionLabel(language);
            break;
          case 'textActionPrompt':
            promptText = _promptConfigService.getTextActionPrompt(language);
            break;
          default:
            promptText = '';
        }
        
        _promptControllers[key]!.text = promptText;
      }
      
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.promptsReset),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error resetting prompts: $e');
    }
  }
  
  Future<void> _saveLanguagePreference(String? languageCode) async {
    await _settingsService.saveLanguage(
      languageCode != null ? Locale(languageCode) : null,
    );
    
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

  Future<void> _saveProvider(String provider) async {
    try {
      await _configService.setProvider(provider);
      setState(() {
        _selectedProvider = provider;
      });
      
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settingsSaved),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error saving provider: $e');
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSavingSettings),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveOpenAIApiKey() async {
    final apiKey = _openaiApiKeyController.text.trim();
    
    // If it's a masked key, don't save it
    if (apiKey.contains('••••')) {
      return;
    }
    
    if (apiKey.isEmpty) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.apiKeyRequired),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      await _configService.setOpenAIApiKey(apiKey);
      setState(() {
        _isOpenAIConfigured = true;
        _showOpenaiApiKey = false;
        _openaiApiKeyController.text = _configService.getOpenAIApiKey() ?? '';
      });
      
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settingsSaved),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error saving OpenAI API key: $e');
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSavingSettings),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveMistralApiKey() async {
    final apiKey = _mistralApiKeyController.text.trim();
    
    // If it's a masked key, don't save it
    if (apiKey.contains('••••')) {
      return;
    }
    
    if (apiKey.isEmpty) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.apiKeyRequired),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      await _configService.setMistralApiKey(apiKey);
      setState(() {
        _isMistralConfigured = true;
        _showMistralApiKey = false;
        _mistralApiKeyController.text = _configService.getMistralApiKey() ?? '';
      });
      
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settingsSaved),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error saving Mistral API key: $e');
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSavingSettings),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildPromptTextField(String key, String label) {
    final controller = _promptControllers[key];
    final focusNode = _promptFocusNodes[key];

    if (controller == null || focusNode == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Container(
          height: 300,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(8),
              border: InputBorder.none,
            ),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildActionLabelField(String key, String label) {
    final controller = _promptControllers[key];
    final focusNode = _promptFocusNodes[key];

    if (controller == null || focusNode == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: 1,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            hintText: label,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildPromptSection(_PromptSection section) {
    return ExpansionTile(
      title: Text(section.title),
      initiallyExpanded: _expansionState[section.stateKey] ?? false,
      onExpansionChanged: (expanded) {
        setState(() {
          _expansionState[section.stateKey] = expanded;
        });
      },
      children: _buildExpansionChildren(
        section.stateKey,
        () {
          final children = <Widget>[];
          final descriptionBuilder = section.descriptionBuilder;
          if (descriptionBuilder != null) {
            children.add(descriptionBuilder(context));
            children.add(const SizedBox(height: 16));
          }
          for (final field in section.fields) {
            children.add(
              field.isLabelField
                  ? _buildActionLabelField(field.key, field.label)
                  : _buildPromptTextField(field.key, field.label),
            );
          }
          return children;
        },
        crossAxisAlignment: section.crossAxisAlignment ?? CrossAxisAlignment.center,
      ),
    );
  }

  List<Widget> _buildPromptSections(AppLocalizations l10n) {
    final sections = <_PromptSection>[
      _PromptSection(
        stateKey: 'chunkSummary',
        title: l10n.chunkSummaryPrompt,
        fields: [
          _PromptFieldConfig('chunkSummary_fr', l10n.chunkSummaryPromptFr),
          _PromptFieldConfig('chunkSummary_en', l10n.chunkSummaryPromptEn),
        ],
      ),
      _PromptSection(
        stateKey: 'characterExtraction',
        title: l10n.characterExtractionPrompt,
        fields: [
          _PromptFieldConfig('characterExtraction_fr', l10n.characterExtractionPromptFr),
          _PromptFieldConfig('characterExtraction_en', l10n.characterExtractionPromptEn),
        ],
      ),
      _PromptSection(
        stateKey: 'batchSummary',
        title: l10n.batchSummaryPrompt,
        fields: [
          _PromptFieldConfig('batchSummary_fr', l10n.batchSummaryPromptFr),
          _PromptFieldConfig('batchSummary_en', l10n.batchSummaryPromptEn),
        ],
      ),
      _PromptSection(
        stateKey: 'narrativeSynthesis',
        title: l10n.narrativeSynthesisPrompt,
        fields: [
          _PromptFieldConfig('narrativeSynthesis_fr', l10n.narrativeSynthesisPromptFr),
          _PromptFieldConfig('narrativeSynthesis_en', l10n.narrativeSynthesisPromptEn),
        ],
      ),
      _PromptSection(
        stateKey: 'textAction',
        title: l10n.textSelectionActionSettings,
        fields: [
          _PromptFieldConfig('textActionLabel_fr', l10n.textSelectionActionLabelFr, isLabelField: true),
          _PromptFieldConfig('textActionLabel_en', l10n.textSelectionActionLabelEn, isLabelField: true),
          _PromptFieldConfig('textActionPrompt_fr', l10n.textSelectionActionPromptFr),
          _PromptFieldConfig('textActionPrompt_en', l10n.textSelectionActionPromptEn),
        ],
        descriptionBuilder: (context) => Text(
          l10n.textSelectionActionDescription(
            Localizations.localeOf(context).languageCode,
            'selected text',
          ),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
        ),
        crossAxisAlignment: CrossAxisAlignment.start,
      ),
    ];

    return sections.map(_buildPromptSection).toList();
  }

  List<Widget> _buildExpansionChildren(
    String sectionKey,
    List<Widget> Function() builder, {
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.center,
  }) {
    if (!(_expansionState[sectionKey] ?? false)) {
      return const [];
    }
    return [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: crossAxisAlignment,
          children: builder(),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.settings),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Language Section
          Text(
            l10n.language,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.languageDescription,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
            title: Text(l10n.languageEnglish),
            value: 'en',
            groupValue: _selectedLanguageCode,
            onChanged: (value) => _saveLanguagePreference(value),
          ),
          RadioListTile<String?>(
            title: Text(l10n.languageFrench),
            value: 'fr',
            groupValue: _selectedLanguageCode,
            onChanged: (value) => _saveLanguagePreference(value),
          ),

          const Divider(height: 32),

          // Summary Provider Section
          Text(
            l10n.summaryProvider,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.summaryProviderDescription,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 16),
          
          // OpenAI Provider Option
          RadioListTile<String>(
            title: Text(l10n.openAIModel),
            subtitle: Text(
              _isOpenAIConfigured 
                  ? l10n.openAIModelConfigured 
                  : l10n.openAIModelNotConfigured,
            ),
            value: 'openai',
            groupValue: _selectedProvider,
            onChanged: _isOpenAIConfigured 
                ? (value) => _saveProvider(value!)
                : null,
          ),
          
          // Mistral Provider Option
          RadioListTile<String>(
            title: const Text('Mistral AI'),
            subtitle: Text(
              _isMistralConfigured 
                  ? 'Mistral API key configured' 
                  : 'Mistral API key not configured',
            ),
            value: 'mistral',
            groupValue: _selectedProvider,
            onChanged: _isMistralConfigured 
                ? (value) => _saveProvider(value!)
                : null,
          ),
          
          const Divider(height: 32),
          
          // OpenAI API Key Section
          Text(
            l10n.openAISettings,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.openAISettingsDescription,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 16),
          
          TextField(
            controller: _openaiApiKeyController,
            obscureText: !_showOpenaiApiKey,
            decoration: InputDecoration(
              labelText: l10n.openAIApiKey,
              hintText: l10n.enterOpenAIApiKey,
              suffixIcon: IconButton(
                icon: Icon(_showOpenaiApiKey ? Icons.visibility : Icons.visibility_off),
                onPressed: () {
                  setState(() {
                    _showOpenaiApiKey = !_showOpenaiApiKey;
                  });
                },
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _saveOpenAIApiKey,
            child: Text(l10n.saveApiKey),
          ),
          
          const Divider(height: 32),
          
          // Mistral API Key Section
          const Text(
            'Mistral AI Settings',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Configure your Mistral AI API key. Get your key from https://console.mistral.ai',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 16),
          
          TextField(
            controller: _mistralApiKeyController,
            obscureText: !_showMistralApiKey,
            decoration: InputDecoration(
              labelText: 'Mistral API Key',
              hintText: 'Enter your Mistral API key',
              suffixIcon: IconButton(
                icon: Icon(_showMistralApiKey ? Icons.visibility : Icons.visibility_off),
                onPressed: () {
                  setState(() {
                    _showMistralApiKey = !_showMistralApiKey;
                  });
                },
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _saveMistralApiKey,
            child: const Text('Save Mistral API Key'),
          ),
          
          const Divider(height: 32),
          
          // Prompt Settings Section
          Text(
            l10n.promptSettings,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.promptSettingsDescription,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 16),
          ..._buildPromptSections(l10n),

          const SizedBox(height: 16),

          // Reset Prompts Button
          ElevatedButton(
            onPressed: _resetPrompts,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: Text(l10n.resetPrompts),
          ),
          
          const SizedBox(height: 32),
          
          // Info Section
          Card(
            color: Colors.blue[50],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      Text(
                        l10n.information,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.blue[900],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.summarySettingsInfo,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.blue[900],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
