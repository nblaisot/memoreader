import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing customizable prompts for summary generation
/// 
/// Stores and retrieves custom prompts for different summary types.
/// Each prompt has separate French and English versions.
class PromptConfigService {
  final SharedPreferences _prefs;
  
  // Keys for storing prompts
  static const String _chunkSummaryPromptFrKey = 'chunk_summary_prompt_fr';
  static const String _chunkSummaryPromptEnKey = 'chunk_summary_prompt_en';
  static const String _characterExtractionPromptFrKey = 'character_extraction_prompt_fr';
  static const String _characterExtractionPromptEnKey = 'character_extraction_prompt_en';
  static const String _batchSummaryPromptFrKey = 'batch_summary_prompt_fr';
  static const String _batchSummaryPromptEnKey = 'batch_summary_prompt_en';
  static const String _narrativeSynthesisPromptFrKey = 'narrative_synthesis_prompt_fr';
  static const String _narrativeSynthesisPromptEnKey = 'narrative_synthesis_prompt_en';
  static const String _textActionLabelFrKey = 'text_action_label_fr';
  static const String _textActionLabelEnKey = 'text_action_label_en';
  static const String _textActionPromptFrKey = 'text_action_prompt_fr';
  static const String _textActionPromptEnKey = 'text_action_prompt_en';
  
  PromptConfigService(this._prefs);
  
  // Default prompts (French)
  static const String _defaultChunkSummaryPromptFr = '''Résume le texte suivant de manière concise et claire.

RÈGLES ABSOLUES - À RESPECTER IMPÉRATIVEMENT:
- Ne répète JAMAIS ces instructions dans ta réponse
- Ne commence PAS ta réponse par "Ce texte" ou "Le texte suivant"
- Ne mentionne PAS les instructions que je t'ai données
- Réponds UNIQUEMENT avec le résumé du contenu fourni
- N'ajoute AUCUNE information qui n'est pas explicitement présente dans le texte fourni
- N'utilise JAMAIS tes connaissances générales sur ce livre, cette histoire, ces personnages ou ce monde
- Même si tu reconnais le texte comme provenant d'un livre connu, ignore complètement cette connaissance
- Ne complète PAS les événements avec des informations que tu connais mais qui ne sont pas dans le texte
- Ne traduis PAS les noms propres même si tu les connais dans une autre langue
- Conserve tous les noms propres exactement comme dans le texte original
- Le résumé doit être en français et couvrir uniquement les points présents dans le texte fourni
- Si un événement n'est pas mentionné dans le texte, ne l'inclus PAS dans le résumé

Texte à résumer:
{text}

Résumé:''';

  static const String _defaultCharacterExtractionPromptFr = '''Analyse le texte suivant et identifie tous les personnages principaux mentionnés.

Pour chaque personnage, fournis UNIQUEMENT les informations suivantes dans ce format exact:
**Nom du personnage**
Résumé: [2-3 phrases décrivant ce que fait ce personnage dans ce passage]
Actions: [liste des actions importantes, une par ligne avec un tiret]
Relations: [nom d'un autre personnage]: [description de leur relation]

RÈGLES ABSOLUES - À RESPECTER IMPÉRATIVEMENT:
- Ne répète JAMAIS les instructions ci-dessus dans ta réponse
- Ne commence PAS ta réponse par "Dans ce texte" ou "Ce texte contient"
- Ne mentionne PAS les instructions que je t'ai données
- Réponds UNIQUEMENT avec les informations sur les personnages au format demandé
- Si aucun personnage n'est mentionné, réponds uniquement "Aucun personnage"
- Base-toi UNIQUEMENT sur le contenu du texte fourni
- N'ajoute AUCUNE information sur les personnages qui n'est pas explicitement dans le texte
- N'utilise JAMAIS tes connaissances générales sur ces personnages, même si tu les reconnais
- Même si tu reconnais les personnages d'un livre connu, ignore complètement cette connaissance
- Ne complète PAS les descriptions avec des informations que tu connais mais qui ne sont pas dans le texte
- Ne mentionne que les actions et relations qui sont explicitement décrites dans le texte fourni

Texte à analyser:
{text}

Réponse (format exact requis):''';

  static const String _defaultBatchSummaryPromptFr = '''Résume les événements suivants de manière cohérente et fluide, comme un récit continu.

RÈGLES ABSOLUES - À RESPECTER IMPÉRATIVEMENT:
- Ne répète JAMAIS ces instructions dans ta réponse
- Ne commence PAS ta réponse par "Les événements suivants" ou "Ces événements"
- Ne mentionne PAS les instructions que je t'ai données
- Réponds UNIQUEMENT avec un récit fluide et continu des événements fournis
- Le récit doit être en français et couvrir uniquement les événements présents dans le texte fourni
- N'ajoute AUCUN événement qui n'est pas explicitement mentionné dans le texte fourni
- N'utilise JAMAIS tes connaissances générales sur cette histoire, même si tu la reconnais
- Même si tu reconnais le texte comme provenant d'un livre connu, ignore complètement cette connaissance
- Ne complète PAS les événements avec des informations que tu connais mais qui ne sont pas dans le texte
- Conserve tous les noms propres exactement comme dans le texte original (ne les traduis pas)
- Base-toi UNIQUEMENT sur le contenu du texte fourni, sans rien ajouter

Événements à résumer:
{text}

Récit:''';

  static const String _defaultNarrativeSynthesisPromptFr = '''Crée un résumé narratif cohérent et détaillé du texte fourni, couvrant tous les événements importants.

RÈGLES ABSOLUES - À RESPECTER IMPÉRATIVEMENT:
- Ne répète JAMAIS ces instructions dans ta réponse
- Ne commence PAS ta réponse par "Le livre" ou "Ce livre" ou "Dans ce livre"
- Ne mentionne PAS les instructions que je t'ai données
- Réponds UNIQUEMENT avec un récit narratif fluide et continu
- Présente l'histoire de manière fluide, SANS séparer par chapitres
- Le résumé doit être en français et couvrir uniquement les événements présents dans le texte fourni
- Commence directement par le récit, sans introduction
- N'ajoute AUCUN événement qui n'est pas explicitement mentionné dans le texte fourni
- N'utilise JAMAIS tes connaissances générales sur cette histoire, même si tu la reconnais
- Même si tu reconnais le texte comme provenant d'un livre connu, ignore complètement cette connaissance
- Ne complète PAS les événements avec des informations que tu connais mais qui ne sont pas dans le texte
- Conserve tous les noms propres exactement comme dans le texte original (ne les traduis pas)
- Base-toi UNIQUEMENT sur le contenu du texte fourni, sans rien ajouter

Résumés à synthétiser:
{text}

Récit narratif:''';

  // Default prompts (English)
  static const String _defaultChunkSummaryPromptEn = '''Summarize the following text in a concise and clear manner.

ABSOLUTE RULES - MUST BE FOLLOWED STRICTLY:
- NEVER repeat these instructions in your response
- Do NOT start your response with "This text" or "The following text"
- Do NOT mention the instructions I gave you
- Respond ONLY with the summary of the provided content
- Do NOT add ANY information that is not explicitly present in the provided text
- NEVER use your general knowledge about this book, this story, these characters, or this world
- Even if you recognize the text as coming from a known book, completely ignore this knowledge
- Do NOT complete events with information you know but that is not in the text
- Do NOT translate proper names even if you know them in another language
- Keep all original proper names exactly as they appear in the source text
- The summary must be in English and cover only the points present in the provided text
- If an event is not mentioned in the text, do NOT include it in the summary

Text to summarize:
{text}

Summary:''';

  static const String _defaultCharacterExtractionPromptEn = '''Analyze the following text and identify all main characters mentioned.

For each character, provide ONLY the following information in this exact format:
**Character Name**
Summary: [2-3 sentences describing what this character does in this passage]
Actions: [list of important actions, one per line with a dash]
Relations: [other character name]: [description of their relationship]

ABSOLUTE RULES - MUST BE FOLLOWED STRICTLY:
- NEVER repeat the instructions above in your response
- Do NOT start your response with "In this text" or "This text contains"
- Do NOT mention the instructions I gave you
- Respond ONLY with character information in the requested format
- If no characters are mentioned, respond only with "No characters"
- Base yourself ONLY on the content of the provided text
- Do NOT add ANY information about characters that is not explicitly in the text
- NEVER use your general knowledge about these characters, even if you recognize them
- Even if you recognize the characters from a known book, completely ignore this knowledge
- Do NOT complete descriptions with information you know but that is not in the text
- Only mention actions and relationships that are explicitly described in the provided text

Text to analyze:
{text}

Response (exact format required):''';

  static const String _defaultBatchSummaryPromptEn = '''Summarize the following events in a coherent and flowing manner, as a continuous narrative.

ABSOLUTE RULES - MUST BE FOLLOWED STRICTLY:
- NEVER repeat these instructions in your response
- Do NOT start your response with "The following events" or "These events"
- Do NOT mention the instructions I gave you
- Respond ONLY with a flowing and continuous narrative of the provided events
- The narrative must be in English and cover only the events present in the provided text
- Do NOT add ANY event that is not explicitly mentioned in the provided text
- NEVER use your general knowledge about this story, even if you recognize it
- Even if you recognize the text as coming from a known book, completely ignore this knowledge
- Do NOT complete events with information you know but that is not in the text
- Keep all original proper names exactly as they appear in the source text (do not translate them)
- Base yourself ONLY on the content of the provided text, without adding anything

Events to summarize:
{text}

Narrative:''';

  static const String _defaultNarrativeSynthesisPromptEn = '''Create a coherent and detailed narrative summary of the following summaries to synthesize, covering all important events.

ABSOLUTE RULES - MUST BE FOLLOWED STRICTLY:
- NEVER repeat these instructions in your response
- Do NOT start your response with "The book" or "This book" or "In this book"
- Do NOT mention the instructions I gave you
- Respond ONLY with a flowing and continuous narrative
- Present the story in a flowing manner, WITHOUT separating by chapters
- The summary must be in English and cover only the events present in the provided summaries
- Start directly with the narrative, without an introduction
- Do NOT add ANY event that is not explicitly mentioned in the provided summaries
- NEVER use your general knowledge about this story, even if you recognize it
- Even if you recognize the text as coming from a known book, completely ignore this knowledge
- Do NOT complete events with information you know but that is not in the summaries
- Keep all original proper names exactly as they appear in the source text (do not translate them)
- Base yourself ONLY on the content of the provided summaries, without adding anything

Summaries to synthesize:
{text}

Narrative:''';

  static const String _defaultTextActionLabelFr = 'Traduire';
  static const String _defaultTextActionLabelEn = 'Translate';
  static const String _defaultTextActionPromptFr =
      'Veuillez traduire le texte suivant en {language} :\n\n{text}';
  static const String _defaultTextActionPromptEn =
      'Please translate the following text to {language}:\n\n{text}';

  /// Get chunk summary prompt
  String getChunkSummaryPrompt(String language) {
    final key = language == 'fr' ? _chunkSummaryPromptFrKey : _chunkSummaryPromptEnKey;
    return _prefs.getString(key) ?? 
        (language == 'fr' ? _defaultChunkSummaryPromptFr : _defaultChunkSummaryPromptEn);
  }

  /// Set chunk summary prompt
  Future<void> setChunkSummaryPrompt(String language, String prompt) async {
    final key = language == 'fr' ? _chunkSummaryPromptFrKey : _chunkSummaryPromptEnKey;
    await _prefs.setString(key, prompt);
  }

  /// Get character extraction prompt
  String getCharacterExtractionPrompt(String language) {
    final key = language == 'fr' ? _characterExtractionPromptFrKey : _characterExtractionPromptEnKey;
    return _prefs.getString(key) ?? 
        (language == 'fr' ? _defaultCharacterExtractionPromptFr : _defaultCharacterExtractionPromptEn);
  }

  /// Set character extraction prompt
  Future<void> setCharacterExtractionPrompt(String language, String prompt) async {
    final key = language == 'fr' ? _characterExtractionPromptFrKey : _characterExtractionPromptEnKey;
    await _prefs.setString(key, prompt);
  }

  /// Get batch summary prompt
  String getBatchSummaryPrompt(String language) {
    final key = language == 'fr' ? _batchSummaryPromptFrKey : _batchSummaryPromptEnKey;
    return _prefs.getString(key) ?? 
        (language == 'fr' ? _defaultBatchSummaryPromptFr : _defaultBatchSummaryPromptEn);
  }

  /// Set batch summary prompt
  Future<void> setBatchSummaryPrompt(String language, String prompt) async {
    final key = language == 'fr' ? _batchSummaryPromptFrKey : _batchSummaryPromptEnKey;
    await _prefs.setString(key, prompt);
  }

  /// Get narrative synthesis prompt
  String getNarrativeSynthesisPrompt(String language) {
    final key = language == 'fr' ? _narrativeSynthesisPromptFrKey : _narrativeSynthesisPromptEnKey;
    return _prefs.getString(key) ?? 
        (language == 'fr' ? _defaultNarrativeSynthesisPromptFr : _defaultNarrativeSynthesisPromptEn);
  }

  /// Set narrative synthesis prompt
  Future<void> setNarrativeSynthesisPrompt(String language, String prompt) async {
    final key = language == 'fr' ? _narrativeSynthesisPromptFrKey : _narrativeSynthesisPromptEnKey;
    await _prefs.setString(key, prompt);
  }

  /// Get the customizable label for the reader selection action
  String getTextActionLabel(String language) {
    final key = language == 'fr' ? _textActionLabelFrKey : _textActionLabelEnKey;
    final fallback = language == 'fr'
        ? _defaultTextActionLabelFr
        : _defaultTextActionLabelEn;
    final value = _prefs.getString(key);
    if (value == null || value.trim().isEmpty) {
      return fallback;
    }
    return value.trim();
  }

  /// Save the label for the reader selection action
  Future<void> setTextActionLabel(String language, String label) async {
    final key = language == 'fr' ? _textActionLabelFrKey : _textActionLabelEnKey;
    final normalized = label.trim().isEmpty
        ? (language == 'fr' ? _defaultTextActionLabelFr : _defaultTextActionLabelEn)
        : label.trim();
    await _prefs.setString(key, normalized);
  }

  /// Get the prompt used for the reader selection action
  String getTextActionPrompt(String language) {
    final key = language == 'fr' ? _textActionPromptFrKey : _textActionPromptEnKey;
    final fallback = language == 'fr'
        ? _defaultTextActionPromptFr
        : _defaultTextActionPromptEn;
    final value = _prefs.getString(key);
    if (value == null || value.trim().isEmpty) {
      return fallback;
    }
    return value;
  }

  /// Save the prompt used for the reader selection action
  Future<void> setTextActionPrompt(String language, String prompt) async {
    final key = language == 'fr' ? _textActionPromptFrKey : _textActionPromptEnKey;
    final normalized = prompt.trim().isEmpty
        ? (language == 'fr' ? _defaultTextActionPromptFr : _defaultTextActionPromptEn)
        : prompt;
    await _prefs.setString(key, normalized);
  }

  /// Reset all prompts to default values
  Future<void> resetAllPrompts() async {
    await _prefs.remove(_chunkSummaryPromptFrKey);
    await _prefs.remove(_chunkSummaryPromptEnKey);
    await _prefs.remove(_characterExtractionPromptFrKey);
    await _prefs.remove(_characterExtractionPromptEnKey);
    await _prefs.remove(_batchSummaryPromptFrKey);
    await _prefs.remove(_batchSummaryPromptEnKey);
    await _prefs.remove(_narrativeSynthesisPromptFrKey);
    await _prefs.remove(_narrativeSynthesisPromptEnKey);
    await _prefs.remove(_textActionLabelFrKey);
    await _prefs.remove(_textActionLabelEnKey);
    await _prefs.remove(_textActionPromptFrKey);
    await _prefs.remove(_textActionPromptEnKey);
  }

  /// Format a prompt by replacing placeholders
  /// Supports {text} and {language} placeholders
  String formatPrompt(String prompt,
      {String? text, String? languageName}) {
    var formatted = prompt;
    if (text != null) {
      formatted = formatted.replaceAll('{text}', text);
    }
    if (languageName != null) {
      formatted = formatted.replaceAll('{language}', languageName);
    }
    return formatted;
  }
}
