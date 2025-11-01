// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'MemoReader';

  @override
  String get library => 'Library';

  @override
  String get importEpub => 'Import EPUB';

  @override
  String get importing => 'Importing...';

  @override
  String get importingEpub => 'Importing EPUB...';

  @override
  String get bookImportedSuccessfully => 'Book imported successfully!';

  @override
  String errorImportingBook(String error) {
    return 'Error importing book: $error';
  }

  @override
  String errorLoadingBooks(String error) {
    return 'Error loading books: $error';
  }

  @override
  String get noBooksInLibrary => 'No books in your library';

  @override
  String get tapToImportEpub => 'Tap the + button to import an EPUB';

  @override
  String get deleteBook => 'Delete Book';

  @override
  String confirmDeleteBook(String title) {
    return 'Are you sure you want to delete \"$title\"?';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String bookDeleted(String title) {
    return '\"$title\" deleted';
  }

  @override
  String errorDeletingBook(String error) {
    return 'Error deleting book: $error';
  }

  @override
  String get refresh => 'Refresh';

  @override
  String get retry => 'Retry';

  @override
  String get chapters => 'Chapters';

  @override
  String chapter(int number) {
    return 'Chapter $number';
  }

  @override
  String get goToPage => 'Go to Page';

  @override
  String get summary => 'Summary';

  @override
  String get backToLibrary => 'Back to Library';

  @override
  String enterPageNumber(int max) {
    return 'Enter page number (1-$max)';
  }

  @override
  String get page => 'Page';

  @override
  String get go => 'Go';

  @override
  String invalidPageNumber(int max) {
    return 'Please enter a page number between 1 and $max';
  }

  @override
  String get noPagesAvailable => 'No pages available';

  @override
  String get noChaptersAvailable => 'No chapters available';

  @override
  String get summaryFeatureComingSoon =>
      'Summary feature will be implemented later with LLM integration.';

  @override
  String get ok => 'OK';

  @override
  String errorLoadingBook(String error) {
    return 'Error loading book: $error';
  }

  @override
  String loadingBook(String title) {
    return 'Loading $title...';
  }

  @override
  String get errorLoadingBookTitle => 'Error Loading Book';

  @override
  String get noContentAvailable => 'No content available in this book.';

  @override
  String get endOfBookReached => 'End of book reached';

  @override
  String get beginningOfBook => 'Beginning of book';

  @override
  String get invalidChapterIndex => 'Invalid chapter index';

  @override
  String errorLoadingChapter(String error) {
    return 'Error loading chapter: $error';
  }

  @override
  String chapterInfo(int current, int total) {
    return 'Chapter $current/$total';
  }

  @override
  String pageInfo(int current, int total) {
    return 'Page $current/$total';
  }

  @override
  String thisChapterHasPages(Object count) {
    return 'This chapter has $count page';
  }

  @override
  String thisChapterHasPages_plural(Object count) {
    return 'This chapter has $count pages';
  }
}
