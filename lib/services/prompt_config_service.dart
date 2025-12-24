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
  static const String _textActionLabelFrKey = 'text_action_label_fr';
  static const String _textActionLabelEnKey = 'text_action_label_en';
  static const String _textActionPromptFrKey = 'text_action_prompt_fr';
  static const String _textActionPromptEnKey = 'text_action_prompt_en';
  
  PromptConfigService(this._prefs);
  
  // Default prompts (French)
  static const String _defaultChunkSummaryPromptFr = '''Résume ce passage de manière détaillée et complète.
Écris un récit fluide, en suivant l'ordre chronologique des événements.

INSTRUCTIONS :
- Divise ton résumé en paragraphes, un par scène ou moment clé.
- Commence chaque paragraphe par un titre court en gras (ex: **Au petit-déjeuner** ou **La confrontation**).
- Dans chaque paragraphe, raconte les événements, les dialogues importants, et ce que les personnages ressentent ou se demandent (si le texte le précise).
- Mets en gras les noms des personnages principaux à leur première mention dans chaque scène.
- N'invente rien, base-toi uniquement sur le texte fourni.
- Écris au présent de narration.

Texte :
{text}

Résumé :''';

  static const String _defaultChunkSummaryPromptEn = '''Summarize this passage in a detailed and complete way.
Write a flowing narrative, following the chronological order of events.

INSTRUCTIONS:
- Divide your summary into paragraphs, one per scene or key moment.
- Start each paragraph with a short bold title (e.g., **At Breakfast** or **The Confrontation**).
- In each paragraph, recount the events, important dialogues, and what the characters feel or wonder about (if the text specifies it).
- Bold the names of main characters at their first mention in each scene.
- Do not invent anything, base yourself only on the provided text.
- Write in the present tense.

Text:
{text}

Summary:''';

  static const String _defaultCharacterExtractionPromptFr = '''Analyse le texte suivant pour extraire les informations clés sur les personnages.

Génère une fiche pour chaque personnage présent, en te concentrant sur son RÔLE ACTIF dans ce passage spécifique.

Pour chaque personnage, utilise EXACTEMENT ce format :
**Nom du personnage**
Résumé: [2-3 phrases sur son rôle dans ce passage précis : qu'a-t-il fait ? qu'a-t-il appris ?]
Actions: [Liste à puces des actions concrètes effectuées]
Relations: [Nom d'un autre personnage]: [Nature de leur interaction dans ce passage]

RÈGLES IMPORTANTES :
- Ignore les personnages simplement mentionnés qui n'apparaissent pas
- Si un personnage n'a ni action ni dialogue significatif, ignore-le
- Ne mentionne que ce qui est EXPLICITEMENT dans le texte
- Ne fais pas d'hypothèses basées sur ta connaissance générale de l'œuvre
- Si aucun personnage significatif n'est présent, réponds "Aucun personnage"

Texte à analyser:
{text}

Réponse (format exact requis):''';

  static const String _defaultCharacterExtractionPromptEn = '''Analyze the following text to extract key information about the characters.

Generate a profile for each character present, focusing on their ACTIVE ROLE in this specific passage.

For each character, use EXACTLY this format:
**Character Name**
Summary: [2-3 sentences on their role in this specific passage: what did they do? what did they learn?]
Actions: [Bulleted list of concrete actions taken]
Relations: [Other character name]: [Nature of their interaction in this passage]

IMPORTANT RULES:
- Ignore characters strictly mentioned who do not appear
- If a character has no significant action or dialogue, ignore them
- Mention ONLY what is EXPLICITLY in the text
- Do NOT make assumptions based on your general knowledge of the work
- If no significant character is present, reply "No characters"

Text to analyze:
{text}

Response (exact format required):''';

  static const String _defaultTextActionLabelFr = 'Traduire';
  static const String _defaultTextActionLabelEn = 'Translate';
  static const String _defaultTextActionPromptFr =
      '''Pour le mot ou la courte phrase suivante, fournis d'abord sa prononciation/romanisation en caractères latins, puis sa traduction en {language}.

INSTRUCTIONS IMPORTANTES :
- Pour les caractères chinois, utilise le pinyin standard avec les marques de ton.
- Pour l'arabe, utilise une translittération latine courante.
- Pour le russe, utilise une translittération latine courante.
- Pour les langues utilisant déjà l'alphabet latin, tu peux répéter le mot comme prononciation ou fournir une syllabification si utile.

FORMAT DE RÉPONSE EXACT (respecte-le strictement, sans texte supplémentaire) :
Original: {text}
Pronunciation: [prononciation en caractères latins]
Translation: [traduction en {language}]

Ne rajoute aucun texte avant ou après ces trois lignes. Réponds uniquement avec ces trois lignes exactement dans cet ordre.

Mot ou phrase à traduire :
{text}''';
  static const String _defaultTextActionPromptEn =
      '''For the following word or short phrase, first provide its pronunciation/romanization in Latin characters, then its translation into {language}.

IMPORTANT INSTRUCTIONS:
- For Chinese characters, use standard pinyin with tone marks.
- For Arabic, use a common Latin transliteration.
- For Russian, use a common Latin transliteration.
- For languages already using the Latin alphabet, you may repeat the word as pronunciation or provide syllabification if helpful.

EXACT RESPONSE FORMAT (follow it strictly, with no additional text):
Original: {text}
Pronunciation: [pronunciation in Latin characters]
Translation: [translation into {language}]

Do not add any text before or after these three lines. Respond only with these three lines exactly in this order.

Word or phrase to translate:
{text}''';

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
