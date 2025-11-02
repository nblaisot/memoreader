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
  String get retry => 'Réessayer';

  @override
  String get chapters => 'Chapitres';

  @override
  String chapter(int number) {
    return 'Chapitre $number';
  }

  @override
  String get goToPage => 'Aller à la page';

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
  String get fontSize => 'Taille de la police';

  @override
  String get fontSizeDescription =>
      'Ajustez la taille du texte lors de la lecture';

  @override
  String get fontSizeExample => 'Ceci est un exemple de taille de texte';

  @override
  String get textSize => 'Taille du texte';

  @override
  String get deleteBookConfirm =>
      'Cela supprimera le livre de la bibliothèque. Êtes-vous sûr ?';

  @override
  String get confirm => 'Confirmer';

  @override
  String get openaiApiKey => 'Clé API OpenAI';

  @override
  String get openaiApiKeyDescription =>
      'Entrez votre clé API OpenAI pour activer les résumés de livres alimentés par l\'IA. Obtenez votre clé sur https://platform.openai.com/api-keys';

  @override
  String get apiKeySaved => 'Clé API enregistrée avec succès';

  @override
  String get generatingSummary => 'Génération du résumé...';

  @override
  String get summaryUpToPosition => 'Résumé jusqu\'à votre position actuelle';

  @override
  String errorGeneratingSummary(String error) {
    return 'Erreur lors de la génération du résumé : $error';
  }

  @override
  String get apiKeyNotConfigured =>
      'Clé API OpenAI non configurée. Veuillez la définir dans les paramètres.';

  @override
  String get enterApiKey => 'Entrez la clé API OpenAI';

  @override
  String get save => 'Enregistrer';

  @override
  String get summaryFromBeginning => 'Résumé depuis le début';

  @override
  String get summarySinceLastTime => 'Résumé depuis la dernière fois';

  @override
  String get summaryCharacters => 'Personnages';

  @override
  String get importantWords => 'Mots importants';

  @override
  String get generatingImportantWords => 'Génération des mots importants...';

  @override
  String errorLoadingImportantWords(String error) {
    return 'Erreur lors du chargement des mots importants : $error';
  }

  @override
  String get whatIsApiKey => 'Qu\'est-ce que c\'est ?';

  @override
  String get apiKeyExplanation =>
      'Une clé API OpenAI est requise pour utiliser les fonctionnalités alimentées par l\'IA comme les résumés automatiques et les mots importants. Vous pouvez obtenir votre clé API depuis la plateforme OpenAI. Après avoir créé un compte, allez dans la section Clés API et créez une nouvelle clé. Gardez-la sécurisée et ne la partagez jamais publiquement.';

  @override
  String get getApiKeyFromOpenAI => 'Obtenir une clé API depuis OpenAI';

  @override
  String get apiKeyCostInfo =>
      'Coûts typiques : Pour un roman moyen comme Sa Majesté des mouches, la génération de résumés coûte environ 10 à 50 centimes (USD) pour l\'ensemble du livre.';

  @override
  String get apiCostLabel => 'Coût estimé de l\'API';

  @override
  String get apiCostDescription =>
      'Ceci affiche le coût cumulatif de tous les appels API effectués dans cette application. Les coûts sont calculés en fonction de l\'utilisation réelle des tokens des réponses OpenAI.';

  @override
  String get resetApiCost => 'Réinitialiser le compteur de coût';

  @override
  String get apiCostReset =>
      'Le compteur de coût de l\'API a été réinitialisé.';

  @override
  String get next => 'Suivant';

  @override
  String get close => 'Fermer';
}
