import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/summary_config_service.dart';
import '../services/settings_service.dart';
import '../services/prompt_config_service.dart';
import '../services/rag_database_service.dart';
import '../services/google_drive_sync_service.dart';
import '../services/drive_sync_secrets_service.dart';
import 'rag_debug_screen.dart';
import '../main.dart';

/// Settings screen for configuring summary provider, API keys, and prompts
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.scrollToSync = false});

  /// When true, scrolls to the Google Drive sync section after load.
  final bool scrollToSync;

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
  double _horizontalPadding = 30.0;
  double _verticalPadding = 50.0;
  int _ragTopK = 10;
  final Map<String, bool> _expansionState = {
    'chunkSummary': false,
    'characterExtraction': false,
    'textAction': false,
  };
  
  // Prompt controllers
  final Map<String, TextEditingController> _promptControllers = {};
  final Map<String, FocusNode> _promptFocusNodes = {};
  
  // Google Drive sync
  final GoogleDriveSyncService _driveSyncService = GoogleDriveSyncService();
  bool _syncEnabled = false;
  String? _accountEmail;
  DateTime? _lastSyncTime;
  bool _isSyncing = false;
  bool _isResettingDrive = false;
  bool _driveEncryptApiKeys = true;
  bool _drivePassphraseConfigured = false;
  bool _driveLegacyHintVisible = false;

  final GlobalKey _googleDriveSyncSectionKey = GlobalKey();
  final ScrollController _settingsListScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  /// Scroll to the Google Drive section using [ScrollController.animateTo] with
  /// [RenderAbstractViewport.getOffsetToReveal]. [Scrollable.ensureVisible] alone
  /// was unreliable here (timing / scroll position not attached).
  void _scrollToGoogleDriveSyncIfRequested() {
    if (!widget.scrollToSync || !mounted) return;

    Future<void> runScroll() async {
      for (var i = 0; i < 150; i++) {
        if (!mounted) return;
        if (i > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (!mounted) return;
        }
        // ignore: use_build_context_synchronously
        // [mounted] checked; [GlobalKey.currentContext] is re-read each iteration.
        final renderObject =
            _googleDriveSyncSectionKey.currentContext?.findRenderObject();
        final controller = _settingsListScrollController;
        if (renderObject != null &&
            renderObject.attached &&
            controller.hasClients) {
          final viewport = RenderAbstractViewport.maybeOf(renderObject);
          if (viewport != null) {
            final revealed =
                viewport.getOffsetToReveal(renderObject, 0.0, axis: Axis.vertical);
            final min = controller.position.minScrollExtent;
            final max = controller.position.maxScrollExtent;
            if (revealed.offset.isFinite) {
              final target = revealed.offset.clamp(min, max);
              await controller.animateTo(
                target,
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeInOut,
              );
              return;
            }
          }
        }
      }
      debugPrint('[Settings] scrollToSync: gave up waiting for scroll target');
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(runScroll());
    });
  }

  @override
  void dispose() {
    _settingsListScrollController.dispose();
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
      
      // Load padding preferences
      _horizontalPadding = await _settingsService.getHorizontalPadding();
      _verticalPadding = await _settingsService.getVerticalPadding();

      // Load RAG settings
      _ragTopK = await _settingsService.getRagTopK();
      
      // Load Google Drive sync settings
      _syncEnabled = await _driveSyncService.isSyncEnabled();
      _accountEmail = await _driveSyncService.getAccountEmail();
      _lastSyncTime = await _driveSyncService.getLastSyncTime();
      _driveEncryptApiKeys =
          await DriveSyncSecretsService.isCloudEncryptionEnabled();
      _drivePassphraseConfigured =
          await DriveSyncSecretsService.hasPassphraseConfigured();
      _driveLegacyHintVisible = _syncEnabled &&
          !await DriveSyncSecretsService.wasLegacyPlaintextHintDismissed();
      
      // Initialize prompt controllers and focus nodes
      _initializePromptControllers();
    } catch (e) {
      debugPrint('Error loading settings: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
      _scrollToGoogleDriveSyncIfRequested();
    }
  }

  void _initializePromptControllers() {
    // Initialize controllers for all prompts
    final promptKeys = [
      'chunkSummary_fr',
      'chunkSummary_en',
      'characterExtraction_fr',
      'characterExtraction_en',
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
  
  Future<void> _saveHorizontalPadding(double padding) async {
    await _settingsService.saveHorizontalPadding(padding);
    
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.horizontalPaddingSaved),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _saveVerticalPadding(double padding) async {
    await _settingsService.saveVerticalPadding(padding);
    
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.verticalPaddingSaved),
          duration: const Duration(seconds: 2),
        ),
      );
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
      await _configService.setProvider('openai');
      setState(() {
        _isOpenAIConfigured = true;
        _showOpenaiApiKey = false;
        _openaiApiKeyController.text = _configService.getOpenAIApiKey() ?? '';
        _selectedProvider = 'openai';
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
      await _configService.setProvider('mistral');
      setState(() {
        _isMistralConfigured = true;
        _showMistralApiKey = false;
        _mistralApiKeyController.text = _configService.getMistralApiKey() ?? '';
        _selectedProvider = 'mistral';
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
      body: SingleChildScrollView(
        controller: _settingsListScrollController,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
          
          // Reader Display Settings Section
          Text(
            l10n?.readerDisplaySettings ?? 'Reader Display Settings',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n?.readerDisplaySettingsDescription ?? 'Adjust the padding of the reader screen. Horizontal padding affects left and right margins, vertical padding affects top and bottom margins.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 16),
          
          // Horizontal Padding
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n?.horizontalPaddingLabel(_horizontalPadding.toStringAsFixed(0)) ?? 'Horizontal Padding (Left/Right): ${_horizontalPadding.toStringAsFixed(0)} px',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Slider(
                      value: _horizontalPadding,
                      min: _settingsService.minPadding,
                      max: _settingsService.maxPadding,
                      divisions: 100,
                      label: '${_horizontalPadding.toStringAsFixed(0)} px',
                      onChanged: (value) {
                        setState(() {
                          _horizontalPadding = value;
                        });
                      },
                      onChangeEnd: (value) {
                        _saveHorizontalPadding(value);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n?.paddingRangeInfo(
              _settingsService.defaultHorizontalPadding.toStringAsFixed(0),
              _settingsService.minPadding.toStringAsFixed(0),
              _settingsService.maxPadding.toStringAsFixed(0),
            ) ?? 'Default: ${_settingsService.defaultHorizontalPadding.toStringAsFixed(0)} px. Range: ${_settingsService.minPadding.toStringAsFixed(0)} - ${_settingsService.maxPadding.toStringAsFixed(0)} px',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),
          
          // Vertical Padding
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n?.verticalPaddingLabel(_verticalPadding.toStringAsFixed(0)) ?? 'Vertical Padding (Top/Bottom): ${_verticalPadding.toStringAsFixed(0)} px',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Slider(
                      value: _verticalPadding,
                      min: _settingsService.minPadding,
                      max: _settingsService.maxPadding,
                      divisions: 100,
                      label: '${_verticalPadding.toStringAsFixed(0)} px',
                      onChanged: (value) {
                        setState(() {
                          _verticalPadding = value;
                        });
                      },
                      onChangeEnd: (value) {
                        _saveVerticalPadding(value);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n?.paddingRangeInfo(
              _settingsService.defaultVerticalPadding.toStringAsFixed(0),
              _settingsService.minPadding.toStringAsFixed(0),
              _settingsService.maxPadding.toStringAsFixed(0),
            ) ?? 'Default: ${_settingsService.defaultVerticalPadding.toStringAsFixed(0)} px. Range: ${_settingsService.minPadding.toStringAsFixed(0)} - ${_settingsService.maxPadding.toStringAsFixed(0)} px',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          
          const Divider(height: 32),
          
          // AI Services Section
          Text(
            l10n.summaryProvider,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  l10n.summaryProviderDescription,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _showAiServicesInfoModal(context, l10n),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
            ],
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
          
          // RAG Database Section
          _buildRagDatabaseSection(context),
          
          // Google Drive Sync Section
          KeyedSubtree(
            key: _googleDriveSyncSectionKey,
            child: _buildGoogleDriveSyncSection(context),
          ),
        ],
        ),
      ),
    );
  }
  
  Widget _buildGoogleDriveSyncSection(BuildContext context) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(
          'Google Drive Sync',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Synchronize your books, reading progress, and saved words across all your devices using Google Drive.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        
        // Enable/Disable Sync Toggle
        SwitchListTile(
          title: const Text('Enable Google Drive Sync'),
          subtitle: Text(
            _syncEnabled 
                ? 'Your data will be synced to Google Drive'
                : 'Sync is disabled',
          ),
          value: _syncEnabled,
          onChanged: (value) async {
            if (value) {
              // Enable sync - sign in first
              final signedIn = await _driveSyncService.signIn();
              if (signedIn) {
                await _driveSyncService.setSyncEnabled(true);
                final email = await _driveSyncService.getAccountEmail();
                final enc =
                    await DriveSyncSecretsService.isCloudEncryptionEnabled();
                final pass =
                    await DriveSyncSecretsService.hasPassphraseConfigured();
                final legacyHint = !await DriveSyncSecretsService
                    .wasLegacyPlaintextHintDismissed();
                setState(() {
                  _syncEnabled = true;
                  _accountEmail = email;
                  _driveEncryptApiKeys = enc;
                  _drivePassphraseConfigured = pass;
                  _driveLegacyHintVisible = legacyHint;
                });
                // Run an initial sync immediately so data is pushed/pulled.
                _driveSyncService.syncOnStartup().then((_) async {
                  if (!mounted) return;
                  final lastSync = await _driveSyncService.getLastSyncTime();
                  setState(() {
                    _lastSyncTime = lastSync;
                  });
                }).catchError((e) {
                  debugPrint('[Settings] Initial sync after enable failed: $e');
                });
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Google Drive sync enabled'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to sign in to Google'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            } else {
              // Disable sync
              await _driveSyncService.setSyncEnabled(false);
              setState(() {
                _syncEnabled = false;
                _accountEmail = null;
                _driveLegacyHintVisible = false;
              });
            }
          },
        ),
        
        if (_syncEnabled) ...[
          const SizedBox(height: 16),
          
          // Account Email
          if (_accountEmail != null)
            ListTile(
              leading: const Icon(Icons.account_circle),
              title: const Text('Account'),
              subtitle: Text(_accountEmail!),
            ),

          SwitchListTile(
            secondary: const Icon(Icons.vpn_key_outlined),
            title: Text(
              AppLocalizations.of(context)!.driveEncryptApiKeysTitle,
            ),
            subtitle: Text(
              _driveEncryptApiKeys
                  ? AppLocalizations.of(context)!.driveEncryptApiKeysSubtitleOn
                  : AppLocalizations.of(context)!
                      .driveEncryptApiKeysSubtitleOff,
            ),
            value: _driveEncryptApiKeys,
            onChanged: (_isSyncing || _isResettingDrive)
                ? null
                : (v) => _onDriveEncryptToggled(context, v),
          ),

          if (_driveEncryptApiKeys) ...[
            Padding(
              padding:
                  const EdgeInsets.only(left: 16, right: 16, bottom: 8, top: 4),
              child: Text(
                AppLocalizations.of(context)!.driveSyncPassphraseDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
            ),
            if (!_drivePassphraseConfigured)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  AppLocalizations.of(context)!
                      .driveSyncPassphraseMissingWarning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade800,
                  ),
                ),
              )
            else
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      color: Colors.green.shade700,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!
                            .driveSyncPassphraseConfigured,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: (_isSyncing || _isResettingDrive)
                    ? null
                    : () => _showDrivePassphraseDialog(context),
                icon: const Icon(Icons.password),
                label: Text(
                  AppLocalizations.of(context)!
                      .driveSyncPassphraseSetButton,
                ),
              ),
            ),
          ],

          if (_driveLegacyHintVisible) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context)!
                          .driveSyncLegacyPlaintextHint,
                      style: theme.textTheme.bodySmall,
                    ),
                    TextButton(
                      onPressed: () async {
                        await DriveSyncSecretsService
                            .dismissLegacyPlaintextHint();
                        if (mounted) {
                          setState(() => _driveLegacyHintVisible = false);
                        }
                      },
                      child: Text(
                        AppLocalizations.of(context)!
                            .driveSyncLegacyPlaintextDismiss,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          ValueListenableBuilder<DriveApiKeysSyncIssue?>(
            valueListenable: _driveSyncService.apiKeysSyncIssue,
            builder: (context, issue, _) {
              if (issue == null) return const SizedBox.shrink();
              final loc = AppLocalizations.of(context)!;
              final msg = switch (issue) {
                DriveApiKeysSyncIssue.missingPassphrase =>
                  loc.driveSyncIssueMissingPassphrase,
                DriveApiKeysSyncIssue.decryptFailed =>
                  loc.driveSyncIssueDecryptFailed,
                DriveApiKeysSyncIssue.unreadableRemote =>
                  loc.driveSyncIssueUnreadableRemote,
              };
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.red.shade800,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            msg,
                            style: TextStyle(color: Colors.red.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),

          // Last Sync Time
          if (_lastSyncTime != null)
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Last Sync'),
              subtitle: Text(
                '${_lastSyncTime!.toLocal().toString().substring(0, 19)}',
              ),
            ),
          
          const SizedBox(height: 16),
          
          // Manual Sync Button
          ElevatedButton.icon(
            onPressed: (_isSyncing || _isResettingDrive)
                ? null
                : () => _manualSync(context),
            icon: _isSyncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(_isSyncing ? 'Syncing...' : 'Sync Now'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          
          const SizedBox(height: 24),
          
          Text(
            'Reset Sync removes all MemoReader data stored in Google Drive '
            'for this account (library metadata, uploaded book files, progress '
            'and word backups). Books and reading state on this device are '
            'not deleted. Other devices will no longer see this cloud data '
            'until you sync or upload again. This cannot be undone.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 12),
          
          OutlinedButton.icon(
            onPressed: (_isSyncing || _isResettingDrive)
                ? null
                : () => _confirmResetGoogleDrive(context),
            icon: _isResettingDrive
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_forever_outlined),
            label: Text(_isResettingDrive ? 'Resetting…' : 'Reset Sync'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              foregroundColor: Colors.red.shade700,
              side: BorderSide(color: Colors.red.shade300),
            ),
          ),
          
          const SizedBox(height: 8),
          
          // Sign Out Button
          OutlinedButton.icon(
            onPressed: (_isSyncing || _isResettingDrive) ? null : () => _signOut(context),
            icon: const Icon(Icons.logout),
            label: const Text('Sign Out'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _onDriveEncryptToggled(
      BuildContext context, bool enabled) async {
    final loc = AppLocalizations.of(context)!;
    if (!enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(loc.driveSyncConfirmDisableEncryptionTitle),
          content: Text(loc.driveSyncConfirmDisableEncryptionBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(loc.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(loc.driveSyncStopEncrypting),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await DriveSyncSecretsService.disableEncryptionAndClearPassphrase();
      setState(() {
        _driveEncryptApiKeys = false;
        _drivePassphraseConfigured = false;
      });
      return;
    }
    await DriveSyncSecretsService.setCloudEncryptionEnabled(true);
    if (!mounted) return;
    setState(() => _driveEncryptApiKeys = true);
  }

  Future<void> _showDrivePassphraseDialog(BuildContext context) async {
    final loc = AppLocalizations.of(context)!;
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    var obscure1 = true;
    var obscure2 = true;
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(loc.driveSyncPassphraseDialogTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: c1,
                      obscureText: obscure1,
                      decoration: InputDecoration(
                        labelText: loc.driveSyncPassphraseField,
                        suffixIcon: IconButton(
                          icon: Icon(obscure1
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () =>
                              setDialogState(() => obscure1 = !obscure1),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: c2,
                      obscureText: obscure2,
                      decoration: InputDecoration(
                        labelText: loc.driveSyncPassphraseConfirmField,
                        suffixIcon: IconButton(
                          icon: Icon(obscure2
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () =>
                              setDialogState(() => obscure2 = !obscure2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(loc.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final p1 = c1.text;
                    final p2 = c2.text;
                    if (p1.length < 8) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(loc.driveSyncPassphraseTooShort)),
                      );
                      return;
                    }
                    if (p1 != p2) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(loc.driveSyncPassphraseMismatch)),
                      );
                      return;
                    }
                    await DriveSyncSecretsService.setPassphrase(p1);
                    await DriveSyncSecretsService.setCloudEncryptionEnabled(
                        true);
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  },
                  child: Text(loc.driveSyncPassphraseSave),
                ),
              ],
            );
          },
        ),
      );
      if (saved == true && mounted) {
        setState(() {
          _drivePassphraseConfigured = true;
          _driveEncryptApiKeys = true;
        });
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.driveSyncPassphraseSaved)),
        );
      }
    } finally {
      c1.dispose();
      c2.dispose();
    }
  }

  Future<void> _confirmResetGoogleDrive(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Google Drive data?'),
        content: const Text(
          'This will permanently delete all MemoReader files stored in '
          'Google Drive for this account (hidden app data: synced library '
          'metadata, EPUBs, covers, progress, and saved words).\n\n'
          'Your library on this phone or tablet is not deleted.\n\n'
          'Signing out is separate and does not erase cloud data by itself.\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove from Drive'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await _runResetGoogleDrive();
  }

  Future<void> _runResetGoogleDrive() async {
    setState(() {
      _isResettingDrive = true;
    });
    try {
      await _driveSyncService.resetRemoteSyncData();
      final lastSync = await _driveSyncService.getLastSyncTime();
      if (!mounted) return;
      setState(() {
        _lastSyncTime = lastSync;
      });
      final loc = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.driveResetSyncBlobQueueCleared),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reset failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isResettingDrive = false;
        });
      }
    }
  }

  Future<void> _manualSync(BuildContext context) async {
    setState(() {
      _isSyncing = true;
    });
    
    try {
      await _driveSyncService.syncOnStartup();
      final lastSync = await _driveSyncService.getLastSyncTime();
      setState(() {
        _lastSyncTime = lastSync;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync completed successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }
  
  Future<void> _signOut(BuildContext context) async {
    await _driveSyncService.signOut();
    await _driveSyncService.setSyncEnabled(false);
    setState(() {
      _syncEnabled = false;
      _accountEmail = null;
      _lastSyncTime = null;
    });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Signed out from Google Drive'),
        ),
      );
    }
  }

  Widget _buildRagDatabaseSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final minTopK = _settingsService.minRagTopK.toDouble();
    final maxTopK = _settingsService.maxRagTopK.toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(
          l10n?.ragDatabaseTitle ?? 'RAG Database',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          l10n?.ragDatabaseDescription ?? 'Manage the RAG (Retrieval-Augmented Generation) database. Clearing the database will delete all indexed chunks and embeddings. Books will be re-indexed automatically.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n?.ragTopKLabel ?? 'RAG context chunks',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          l10n?.ragTopKDescription ??
              'Number of relevant chunks attached to each question.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                min: minTopK,
                max: maxTopK,
                divisions: maxTopK.toInt() - minTopK.toInt(),
                value: _ragTopK.toDouble().clamp(minTopK, maxTopK),
                label: _ragTopK.toString(),
                onChanged: (value) {
                  final rounded = value.round();
                  if (rounded != _ragTopK) {
                    setState(() {
                      _ragTopK = rounded;
                    });
                  }
                },
                onChangeEnd: (value) async {
                  final rounded = value.round();
                  await _settingsService.saveRagTopK(rounded);
                },
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                _ragTopK.toString(),
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const RagDebugScreen(),
              ),
            );
          },
          icon: const Icon(Icons.bug_report),
          label: Text(l10n?.debugRagChunks ?? 'Debug RAG Chunks'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: () => _showClearRagDatabaseDialog(context),
          icon: const Icon(Icons.delete_outline),
          label: Text(l10n?.ragClearDatabase ?? 'Clear RAG database'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.errorContainer,
            foregroundColor: theme.colorScheme.onErrorContainer,
          ),
        ),
      ],
    );
  }

  void _showAiServicesInfoModal(BuildContext context, AppLocalizations l10n) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.information),
        content: SingleChildScrollView(
          child: Text(l10n.aiServicesInfoModal),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _showClearRagDatabaseDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n?.ragClearDatabase ?? 'Clear RAG database'),
        content: Text(
          l10n?.ragClearDatabaseConfirm ??
              'This will delete all indexed chunks and embeddings. Books will be re-indexed automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n?.cancel ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n?.delete ?? 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _clearRagDatabase(context);
    }
  }

  Future<void> _clearRagDatabase(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final ragDbService = RagDatabaseService();
      await ragDbService.clearAll();

      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l10n?.ragClearDatabaseConfirm ?? 'RAG database cleared successfully',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error clearing RAG database: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
}
