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
  String get importEpub => 'Importer un livre';

  @override
  String get importing => 'Importation...';

  @override
  String get importingEpub => 'Importation du livre...';

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
  String get bookFileNotFound =>
      'Fichier du livre introuvable. Le fichier a peut-être été déplacé ou supprimé.';

  @override
  String get noBooksInLibrary => 'Aucun livre dans votre bibliothèque';

  @override
  String get tapToImportEpub =>
      'Appuyez sur le bouton + pour importer un fichier EPUB, TXT ou PDF';

  @override
  String get libraryEmptyInfo =>
      'Importez des livres .epub, des documents .txt ou des fichiers .pdf, dans n\'importe quelle langue.';

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
  String get summariesSectionTitle => 'Résumés';

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
  String get summaryDeleted => 'Résumé supprimé';

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
  String get summaryProvider => 'Services IA';

  @override
  String get summaryProviderDescription =>
      'Sélectionnez la plate-forme IA pour les services de résumé, traduction et recherches RAG';

  @override
  String get aiServicesInfoModal =>
      'Memoreader est une application autonome, elle a besoin d\'appeler OpenAI ou Mistral pour fonctionner. Ces appels ont un coût (très faible), et donc requiert que vous vous connectiez sur leur site pour vous procurer une « clé API », pour pouvoir appeler le service en VOTRE nom — et pour que vous puissiez payer pour. Demandez à ChatGPT ou à Le Chat comment faire !';

  @override
  String get summaryProviderMissing =>
      'Configurez un fournisseur de résumés dans les paramètres pour générer des résumés.';

  @override
  String get promptSettings => 'Paramètres des instructions';

  @override
  String get promptSettingsDescription =>
      'Personnalisez les instructions utilisées pour la génération de résumés. Vous pouvez utiliser des variables dans vos instructions : text (pour le texte à résumer), bookTitle (pour le titre du livre), et chapterTitle (pour le titre du chapitre). Écrivez-les avec des accolades dans vos instructions.';

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
  String get chunkSummaryPrompt => 'Instruction de résumé de fragment';

  @override
  String get chunkSummaryPromptFr =>
      'Instruction de résumé de fragment (Français)';

  @override
  String get chunkSummaryPromptEn =>
      'Instruction de résumé de fragment (Anglais)';

  @override
  String get characterExtractionPrompt =>
      'Instruction d\'extraction de personnages';

  @override
  String get characterExtractionPromptFr =>
      'Instruction d\'extraction de personnages (Français)';

  @override
  String get characterExtractionPromptEn =>
      'Instruction d\'extraction de personnages (Anglais)';

  @override
  String get batchSummaryPrompt => 'Instruction de résumé par lot';

  @override
  String get batchSummaryPromptFr => 'Instruction de résumé par lot (Français)';

  @override
  String get batchSummaryPromptEn => 'Instruction de résumé par lot (Anglais)';

  @override
  String get narrativeSynthesisPrompt => 'Instruction de synthèse narrative';

  @override
  String get narrativeSynthesisPromptFr =>
      'Instruction de synthèse narrative (Français)';

  @override
  String get narrativeSynthesisPromptEn =>
      'Instruction de synthèse narrative (Anglais)';

  @override
  String get fallbackSummaryPrompt => 'Instruction de résumé de secours';

  @override
  String get fallbackSummaryPromptFr =>
      'Instruction de résumé de secours (Français)';

  @override
  String get fallbackSummaryPromptEn =>
      'Instruction de résumé de secours (Anglais)';

  @override
  String get conciseSummaryPrompt => 'Instruction de résumé concis';

  @override
  String get conciseSummaryPromptFr =>
      'Instruction de résumé concis (Français)';

  @override
  String get conciseSummaryPromptEn => 'Instruction de résumé concis (Anglais)';

  @override
  String get resetPrompts => 'Réinitialiser aux valeurs par défaut';

  @override
  String get promptsReset =>
      'Instructions réinitialisées aux valeurs par défaut';

  @override
  String get promptSaved => 'Instruction enregistrée';

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
      'OpenAI et Mistral AI fournissent des résumés rapides et précis mais nécessitent une connexion Internet et une clé API. Configurez votre fournisseur préféré et personnalisez les instructions utilisées pour la génération de résumés.';

  @override
  String get generatingSummary => 'Génération du résumé...';

  @override
  String get summaryReset => 'Réinitialiser ce résumé';

  @override
  String get summaryStatusPreparing => 'Préparation...';

  @override
  String summaryStatusCalling(String provider) {
    return 'Appel de $provider...';
  }

  @override
  String get summaryFoundInCache => 'Résumé trouvé dans le cache';

  @override
  String get summariesDeleteAction => 'Supprimer les résumés';

  @override
  String get summariesDeleteConfirmTitle => 'Supprimer les résumés ?';

  @override
  String get summariesDeleteConfirmBody =>
      'Cela supprimera définitivement tous les résumés mis en cache pour ce livre. Continuer ?';

  @override
  String get summariesDeleteConfirmButton => 'Supprimer les résumés';

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
  String get summaryFromBeginning => 'Depuis le début';

  @override
  String get summarySinceLastTime => 'Depuis la dernière fois';

  @override
  String get horizontalPaddingSaved =>
      'Marge horizontale enregistrée. Les modifications s\'appliqueront lors de la réouverture d\'un livre.';

  @override
  String get verticalPaddingSaved =>
      'Marge verticale enregistrée. Les modifications s\'appliqueront lors de la réouverture d\'un livre.';

  @override
  String get summaryCharacters => 'Personnages';

  @override
  String get pronunciation => 'Prononciation';

  @override
  String get translation => 'Traduction';

  @override
  String get savedWords => 'Mots sauvegardés';

  @override
  String get saveTranslation => 'Enregistrer';

  @override
  String get translationSaved => 'Traduction enregistrée';

  @override
  String get copyAsTsv => 'Copier en TSV';

  @override
  String get tsvCopied => 'Copié dans le presse-papiers';

  @override
  String get noSavedWords => 'Aucun mot sauvegardé';

  @override
  String get filterSavedWords => 'Filtrer...';

  @override
  String get deleteTranslation => 'Supprimer cette traduction ?';

  @override
  String get deleteTranslationConfirm => 'Supprimer';

  @override
  String get repaginating => 'Pagination...';

  @override
  String get ragAskQuestion => 'Poser une question';

  @override
  String ragIndexingProgress(int percentage) {
    return 'Indexation en cours ($percentage%)';
  }

  @override
  String get ragIndexingInitializing => 'Indexation en cours (...)';

  @override
  String get ragQuestionField => 'Entrez votre question';

  @override
  String get ragAskReadSoFar => 'Demander sur ce que j\'ai lu jusqu\'à présent';

  @override
  String get ragAskWholeBook => 'Demander sur tout le livre';

  @override
  String get ragSubmitQuestion => 'Envoyer';

  @override
  String get ragAnswerLabel => 'Réponse';

  @override
  String get ragSourcesLabel => 'Sources';

  @override
  String get ragErrorGeneric =>
      'Une erreur s\'est produite lors du traitement de votre question';

  @override
  String get ragNotIndexed =>
      'Le livre n\'est pas encore indexé. Veuillez attendre que l\'indexation soit terminée.';

  @override
  String get ragClearDatabase => 'Effacer la base de données RAG';

  @override
  String get ragClearDatabaseConfirm =>
      'Cela supprimera tous les fragments indexés et les embeddings. Les livres seront ré-indexés automatiquement.';

  @override
  String get ragTopKLabel => 'Fragments de contexte RAG';

  @override
  String get ragTopKDescription =>
      'Nombre de fragments pertinents attachés à chaque question.';

  @override
  String get ragLatestEvents => 'Quels sont les derniers événements?';

  @override
  String get ragLatestEventsTitle =>
      'Derniers événements depuis cette position';

  @override
  String get ragLatestEventsPrompt => 'Résumé des événements récents';

  @override
  String get ragAutoShowLatestEvents =>
      'Afficher automatiquement à la réouverture';

  @override
  String get ragAutoShowDescription =>
      'Ce résumé s\'affichera automatiquement lors de la réouverture du livre ou de l\'application';

  @override
  String get ragLatestEventsGenerating =>
      'Génération du résumé des derniers événements...';

  @override
  String ragIndexingCompleted(int chunks, int apiCalls) {
    return 'Indexation terminée : $chunks fragments indexés, $apiCalls appels API';
  }

  @override
  String get readerMenuTitle => 'Options de lecture';

  @override
  String get questionsSectionTitle => 'Questions';

  @override
  String get goToChapter => 'Aller au chapitre';

  @override
  String get readerDisplaySettings => 'Paramètres d\'affichage du lecteur';

  @override
  String get readerDisplaySettingsDescription =>
      'Ajustez les marges de l\'écran de lecture. La marge horizontale affecte les bords gauche et droit, la marge verticale affecte les bords haut et bas.';

  @override
  String horizontalPaddingLabel(String value) {
    return 'Marge horizontale (gauche/droite) : $value px';
  }

  @override
  String verticalPaddingLabel(String value) {
    return 'Marge verticale (haut/bas) : $value px';
  }

  @override
  String paddingRangeInfo(String defaultValue, String min, String max) {
    return 'Par défaut : $defaultValue px. Plage : $min - $max px';
  }

  @override
  String get ragDatabaseTitle => 'Base de données RAG';

  @override
  String get ragDatabaseDescription =>
      'Gérez la base de données RAG (Génération Augmentée par Récupération). Effacer la base de données supprimera tous les fragments indexés et les embeddings. Les livres seront ré-indexés automatiquement.';

  @override
  String get debugRagChunks => 'Déboguer les fragments RAG';
}
