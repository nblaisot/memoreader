// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'MemoReader';

  @override
  String get library => 'Bibliothèque';

  @override
  String get importEpub => 'Importer EPUB';

  @override
  String get importing => 'Importation...';

  @override
  String get importingEpub => 'Importation de l\'EPUB...';

  @override
  String get bookImportedSuccessfully => 'Livre importé avec succès !';

  @override
  String errorImportingBook(String error) {
    return 'Erreur lors de l\'importation du livre : $error';
  }

  @override
  String errorLoadingBooks(String error) {
    return 'Erreur lors du chargement des livres : $error';
  }

  @override
  String get noBooksInLibrary => 'Aucun livre dans votre bibliothèque';

  @override
  String get tapToImportEpub => 'Appuyez sur le bouton + pour importer un EPUB';

  @override
  String get deleteBook => 'Supprimer le livre';

  @override
  String confirmDeleteBook(String title) {
    return 'Êtes-vous sûr de vouloir supprimer \"$title\" ?';
  }

  @override
  String get cancel => 'Annuler';

  @override
  String get delete => 'Supprimer';

  @override
  String bookDeleted(String title) {
    return '\"$title\" supprimé';
  }

  @override
  String errorDeletingBook(String error) {
    return 'Erreur lors de la suppression du livre : $error';
  }

  @override
  String get refresh => 'Actualiser';

  @override
  String get libraryShowGrid => 'Vue grille';

  @override
  String get libraryShowList => 'Vue liste';

  @override
  String get retry => 'Réessayer';

  @override
  String get chapters => 'Chapitres';

  @override
  String get tableOfContents => 'Table des matières';

  @override
  String chapter(int number) {
    return 'Chapitre $number';
  }

  @override
  String get goToPage => 'Aller à la page';

  @override
  String get goToPercentage => 'Aller à % de progression';

  @override
  String get enterPercentage => 'Entrez un pourcentage de progression (0-100)';

  @override
  String get invalidPercentage => 'Veuillez saisir une valeur entre 0 et 100';

  @override
  String get summary => 'Résumé';

  @override
  String get backToLibrary => 'Retour à la bibliothèque';

  @override
  String enterPageNumber(int max) {
    return 'Entrez le numéro de page (1-$max)';
  }

  @override
  String get page => 'Page';

  @override
  String get go => 'Aller';

  @override
  String invalidPageNumber(int max) {
    return 'Veuillez entrer un numéro de page entre 1 et $max';
  }

  @override
  String get noPagesAvailable => 'Aucune page disponible';

  @override
  String get noChaptersAvailable => 'Aucun chapitre disponible';

  @override
  String get resetSummaries => 'Réinitialiser';

  @override
  String get summariesReset => 'Résumés réinitialisés';

  @override
  String get resetSummariesError =>
      'Impossible de réinitialiser les résumés. Veuillez réessayer.';

  @override
  String get summaryFeatureComingSoon =>
      'La fonctionnalité de résumé sera implémentée plus tard avec l\'intégration LLM.';

  @override
  String get ok => 'OK';

  @override
  String errorLoadingBook(String error) {
    return 'Erreur lors du chargement du livre : $error';
  }

  @override
  String loadingBook(String title) {
    return 'Chargement de $title...';
  }

  @override
  String get errorLoadingBookTitle => 'Erreur lors du chargement du livre';

  @override
  String get noContentAvailable => 'Aucun contenu disponible dans ce livre.';

  @override
  String get endOfBookReached => 'Fin du livre atteinte';

  @override
  String get beginningOfBook => 'Début du livre';

  @override
  String get invalidChapterIndex => 'Index de chapitre invalide';

  @override
  String errorLoadingChapter(String error) {
    return 'Erreur lors du chargement du chapitre : $error';
  }

  @override
  String chapterInfo(int current, int total) {
    return 'Chapitre $current/$total';
  }

  @override
  String pageInfo(int current, int total) {
    return 'Page $current/$total';
  }

  @override
  String thisChapterHasPages(Object count) {
    return 'Ce chapitre contient $count page';
  }

  @override
  String thisChapterHasPages_plural(Object count) {
    return 'Ce chapitre contient $count pages';
  }

  @override
  String get settings => 'Paramètres';

  @override
  String get summaryProvider => 'Fournisseur de résumés';

  @override
  String get summaryProviderDescription =>
      'Choisissez comment les résumés sont générés';

  @override
  String get summaryProviderMissing =>
      'Configurez un fournisseur de résumés dans les paramètres pour générer des résumés.';

  @override
  String get promptSettings => 'Paramètres des prompts';

  @override
  String get promptSettingsDescription =>
      'Personnalisez les prompts utilisés pour la génération de résumés. Vous pouvez utiliser des placeholders dans vos prompts : text (pour le texte à résumer), bookTitle (pour le titre du livre), et chapterTitle (pour le titre du chapitre). Écrivez-les avec des accolades dans vos prompts.';

  @override
  String get textSelectionActionSettings => 'Action de sélection de texte';

  @override
  String textSelectionActionDescription(Object language, Object text) {
    return 'Personnalisez l\'action affichée lors de la sélection de texte. Vous pouvez utiliser $text pour le texte sélectionné et $language pour la langue de l\'application.';
  }

  @override
  String get textSelectionActionLabelFr => 'Libellé de l\'action (français)';

  @override
  String get textSelectionActionLabelEn => 'Libellé de l\'action (anglais)';

  @override
  String get textSelectionActionPromptFr => 'Invite de l\'action (français)';

  @override
  String get textSelectionActionPromptEn => 'Invite de l\'action (anglais)';

  @override
  String get textSelectionActionProcessing => 'Traitement de la sélection...';

  @override
  String get textSelectionActionError =>
      'Impossible de traiter le texte sélectionné.';

  @override
  String get textSelectionSelectedTextLabel => 'Texte sélectionné';

  @override
  String get textSelectionActionResultLabel => 'Réponse';

  @override
  String get textSelectionDefaultLabel => 'Traduire';

  @override
  String get summaryConfigurationRequiredTitle => 'Configuration requise';

  @override
  String get summaryConfigurationRequiredBody =>
      'Pour utiliser cette fonctionnalité, vous devez configurer un fournisseur d\'IA dans les paramètres. Voulez-vous ouvrir les paramètres maintenant ?';

  @override
  String get appLanguageName => 'Français';

  @override
  String get chunkSummaryPrompt => 'Prompt de résumé de chunk';

  @override
  String get chunkSummaryPromptFr => 'Prompt de résumé de chunk (Français)';

  @override
  String get chunkSummaryPromptEn => 'Prompt de résumé de chunk (Anglais)';

  @override
  String get characterExtractionPrompt => 'Prompt d\'extraction de personnages';

  @override
  String get characterExtractionPromptFr =>
      'Prompt d\'extraction de personnages (Français)';

  @override
  String get characterExtractionPromptEn =>
      'Prompt d\'extraction de personnages (Anglais)';

  @override
  String get batchSummaryPrompt => 'Prompt de résumé par batch';

  @override
  String get batchSummaryPromptFr => 'Prompt de résumé par batch (Français)';

  @override
  String get batchSummaryPromptEn => 'Prompt de résumé par batch (Anglais)';

  @override
  String get narrativeSynthesisPrompt => 'Prompt de synthèse narrative';

  @override
  String get narrativeSynthesisPromptFr =>
      'Prompt de synthèse narrative (Français)';

  @override
  String get narrativeSynthesisPromptEn =>
      'Prompt de synthèse narrative (Anglais)';

  @override
  String get fallbackSummaryPrompt => 'Prompt de résumé de fallback';

  @override
  String get fallbackSummaryPromptFr =>
      'Prompt de résumé de fallback (Français)';

  @override
  String get fallbackSummaryPromptEn =>
      'Prompt de résumé de fallback (Anglais)';

  @override
  String get conciseSummaryPrompt => 'Prompt de résumé concis';

  @override
  String get conciseSummaryPromptFr => 'Prompt de résumé concis (Français)';

  @override
  String get conciseSummaryPromptEn => 'Prompt de résumé concis (Anglais)';

  @override
  String get resetPrompts => 'Réinitialiser aux valeurs par défaut';

  @override
  String get promptsReset => 'Prompts réinitialisés aux valeurs par défaut';

  @override
  String get promptSaved => 'Prompt enregistré';

  @override
  String get openAIModel => 'OpenAI (GPT)';

  @override
  String get openAIModelConfigured => 'Configuré - Nécessite Internet';

  @override
  String get openAIModelNotConfigured => 'Non configuré - Clé API requise';

  @override
  String get openAISettings => 'Paramètres OpenAI';

  @override
  String get openAISettingsDescription =>
      'Entrez votre clé API OpenAI pour utiliser GPT pour les résumés';

  @override
  String get openAIApiKey => 'Clé API OpenAI';

  @override
  String get enterOpenAIApiKey => 'Entrez votre clé API OpenAI';

  @override
  String get saveApiKey => 'Enregistrer la clé API';

  @override
  String get apiKeyRequired => 'La clé API est requise';

  @override
  String get settingsSaved => 'Paramètres enregistrés';

  @override
  String get errorSavingSettings =>
      'Erreur lors de l\'enregistrement des paramètres';

  @override
  String get information => 'Information';

  @override
  String get summarySettingsInfo =>
      'OpenAI et Mistral AI fournissent des résumés rapides et précis mais nécessitent une connexion Internet et une clé API. Configurez votre fournisseur préféré et personnalisez les prompts utilisés pour la génération de résumés.';

  @override
  String get generatingSummary => 'Génération du résumé...';

  @override
  String errorGeneratingSummary(String error) {
    return 'Erreur lors de la génération du résumé : $error';
  }

  @override
  String summaryForChapter(String title) {
    return 'Résumé pour $title';
  }

  @override
  String get noSummaryAvailable => 'Aucun résumé disponible';

  @override
  String get deleteBookConfirm =>
      'Cela supprimera le livre de la bibliothèque. Êtes-vous sûr ?';

  @override
  String get confirm => 'Confirmer';

  @override
  String get textSize => 'Taille du texte';

  @override
  String get language => 'Langue';

  @override
  String get languageDescription =>
      'Choisissez votre langue préférée. Les modifications nécessitent un redémarrage de l\'application.';

  @override
  String get languageSystemDefault => 'Par défaut (système)';

  @override
  String get languageSystemDefaultDescription =>
      'Utiliser les paramètres de langue de l\'appareil';

  @override
  String get languageChangedRestart =>
      'Préférence de langue enregistrée. Veuillez redémarrer l\'application pour que les modifications prennent effet.';

  @override
  String get languageEnglish => 'Anglais';

  @override
  String get languageFrench => 'Français';

  @override
  String get summariesSectionTitle => 'Résumés';

  @override
  String get summaryReset => 'Réinitialiser ce résumé';

  @override
  String get summaryStatusPreparing => 'Préparation...';

  @override
  String summaryStatusCalling(Object provider) => 'Appel de $provider...';

  @override
  String get summaryFromBeginning => 'Depuis le début';

  @override
  String get summarySinceLastTime => 'Depuis la dernière fois';

  @override
  String get horizontalPaddingSaved =>
      'Padding horizontal enregistré. Les modifications s\'appliqueront lors de la réouverture d\'un livre.';

  @override
  String get verticalPaddingSaved =>
      'Padding vertical enregistré. Les modifications s\'appliqueront lors de la réouverture d\'un livre.';

  @override
  String get summaryCharacters => 'Personnages';
}
