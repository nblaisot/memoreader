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
}
