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

  @override
  String get settings => 'Settings';

  @override
  String get language => 'Language';

  @override
  String get languageDescription =>
      'Choose your preferred language. Changes require app restart.';

  @override
  String get languageSystemDefault => 'System Default';

  @override
  String get languageSystemDefaultDescription => 'Use device language settings';

  @override
  String get languageChangedRestart =>
      'Language preference saved. Please restart the app for changes to take effect.';

  @override
  String get fontSize => 'Font Size';

  @override
  String get fontSizeDescription => 'Adjust the size of the text when reading';

  @override
  String get fontSizeExample => 'This is an example of text size';

  @override
  String get textSize => 'Text size';

  @override
  String get deleteBookConfirm =>
      'This will delete the book from the library. Are you sure?';

  @override
  String get confirm => 'Confirm';

  @override
  String get openaiApiKey => 'OpenAI API Key';

  @override
  String get openaiApiKeyDescription =>
      'Enter your OpenAI API key to enable AI-powered book summaries. Get your key at https://platform.openai.com/api-keys';

  @override
  String get apiKeySaved => 'API key saved successfully';

  @override
  String get generatingSummary => 'Generating summary...';

  @override
  String get summaryUpToPosition => 'Summary up to your current position';

  @override
  String errorGeneratingSummary(String error) {
    return 'Error generating summary: $error';
  }

  @override
  String get apiKeyNotConfigured =>
      'OpenAI API key not configured. Please set it in settings.';

  @override
  String get enterApiKey => 'Enter OpenAI API Key';

  @override
  String get save => 'Save';

  @override
  String get summaryFromBeginning => 'Summary from the beginning';

  @override
  String get summarySinceLastTime => 'Summary since last time';

  @override
  String get summaryCharacters => 'Characters';

  @override
  String get importantWords => 'Important Words';

  @override
  String get generatingImportantWords => 'Generating important words...';

  @override
  String errorLoadingImportantWords(String error) {
    return 'Error loading important words: $error';
  }

  @override
  String get whatIsApiKey => 'What is that?';

  @override
  String get apiKeyExplanation =>
      'An OpenAI API key is required to use the AI-powered features like automatic summaries and important words. You can get your API key from OpenAI\'s platform. After creating an account, go to API Keys section and create a new key. Keep it secure and never share it publicly.';

  @override
  String get getApiKeyFromOpenAI => 'Get API Key from OpenAI';

  @override
  String get apiKeyCostInfo =>
      'Typical costs: For an average novel like Lord of the Flies, generating summaries costs approximately 10-50 cents (USD) for the entire book.';

  @override
  String get apiCostLabel => 'Estimated API Cost';

  @override
  String get apiCostDescription =>
      'This shows the cumulative cost of all API calls made in this app. Costs are calculated based on actual token usage from OpenAI responses.';

  @override
  String get resetApiCost => 'Reset Cost Counter';

  @override
  String get apiCostReset => 'API cost counter has been reset.';

  @override
  String get next => 'Next';

  @override
  String get close => 'Close';
}
