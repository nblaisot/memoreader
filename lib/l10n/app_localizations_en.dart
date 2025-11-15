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
  String get libraryShowGrid => 'Grid view';

  @override
  String get libraryShowList => 'List view';

  @override
  String get retry => 'Retry';

  @override
  String get chapters => 'Chapters';

  @override
  String get tableOfContents => 'Table of Contents';

  @override
  String chapter(int number) {
    return 'Chapter $number';
  }

  @override
  String get goToPage => 'Go to Page';

  @override
  String get goToPercentage => 'Go to % progress';

  @override
  String get enterPercentage => 'Enter progress percentage (0-100)';

  @override
  String get invalidPercentage => 'Please enter a value between 0 and 100';

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
  String get resetSummaries => 'Reset summaries';

  @override
  String get summariesReset => 'Summaries reset';

  @override
  String get resetSummariesError =>
      'Unable to reset summaries. Please try again.';

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
  String get summaryProvider => 'Summary Provider';

  @override
  String get summaryProviderDescription => 'Choose how summaries are generated';

  @override
  String get summaryProviderMissing =>
      'Configure a summary provider in Settings to generate summaries.';

  @override
  String get promptSettings => 'Prompt Settings';

  @override
  String get promptSettingsDescription =>
      'Customize the prompts used for summary generation. You can use placeholders in your prompts: text (for the text to summarize), bookTitle (for the book title), and chapterTitle (for the chapter title). Write them with curly braces in your prompts.';

  @override
  String get textSelectionActionSettings => 'Text selection action';

  @override
  String textSelectionActionDescription(Object language, Object text) {
    return 'Customize the action displayed when selecting text. You can use $text for the selected text and $language for the application language.';
  }

  @override
  String get textSelectionActionLabelFr => 'Action label (French)';

  @override
  String get textSelectionActionLabelEn => 'Action label (English)';

  @override
  String get textSelectionActionPromptFr => 'Action prompt (French)';

  @override
  String get textSelectionActionPromptEn => 'Action prompt (English)';

  @override
  String get textSelectionActionProcessing => 'Processing selection...';

  @override
  String get textSelectionActionError => 'Unable to process the selected text.';

  @override
  String get textSelectionSelectedTextLabel => 'Selected text';

  @override
  String get textSelectionActionResultLabel => 'Response';

  @override
  String get textSelectionDefaultLabel => 'Translate';

  @override
  String get summaryConfigurationRequiredTitle => 'Configuration required';

  @override
  String get summaryConfigurationRequiredBody =>
      'To use this feature you need to configure an AI provider in the settings. Would you like to open the settings now?';

  @override
  String get appLanguageName => 'English';

  @override
  String get chunkSummaryPrompt => 'Chunk Summary Prompt';

  @override
  String get chunkSummaryPromptFr => 'Chunk Summary Prompt (French)';

  @override
  String get chunkSummaryPromptEn => 'Chunk Summary Prompt (English)';

  @override
  String get characterExtractionPrompt => 'Character Extraction Prompt';

  @override
  String get characterExtractionPromptFr =>
      'Character Extraction Prompt (French)';

  @override
  String get characterExtractionPromptEn =>
      'Character Extraction Prompt (English)';

  @override
  String get batchSummaryPrompt => 'Batch Summary Prompt';

  @override
  String get batchSummaryPromptFr => 'Batch Summary Prompt (French)';

  @override
  String get batchSummaryPromptEn => 'Batch Summary Prompt (English)';

  @override
  String get narrativeSynthesisPrompt => 'Narrative Synthesis Prompt';

  @override
  String get narrativeSynthesisPromptFr =>
      'Narrative Synthesis Prompt (French)';

  @override
  String get narrativeSynthesisPromptEn =>
      'Narrative Synthesis Prompt (English)';

  @override
  String get fallbackSummaryPrompt => 'Fallback Summary Prompt';

  @override
  String get fallbackSummaryPromptFr => 'Fallback Summary Prompt (French)';

  @override
  String get fallbackSummaryPromptEn => 'Fallback Summary Prompt (English)';

  @override
  String get conciseSummaryPrompt => 'Concise Summary Prompt';

  @override
  String get conciseSummaryPromptFr => 'Concise Summary Prompt (French)';

  @override
  String get conciseSummaryPromptEn => 'Concise Summary Prompt (English)';

  @override
  String get resetPrompts => 'Reset to Default';

  @override
  String get promptsReset => 'Prompts reset to default values';

  @override
  String get promptSaved => 'Prompt saved';

  @override
  String get openAIModel => 'OpenAI (GPT)';

  @override
  String get openAIModelConfigured => 'Configured - Requires internet';

  @override
  String get openAIModelNotConfigured => 'Not configured - API key required';

  @override
  String get openAISettings => 'OpenAI Settings';

  @override
  String get openAISettingsDescription =>
      'Enter your OpenAI API key to use GPT for summaries';

  @override
  String get openAIApiKey => 'OpenAI API Key';

  @override
  String get enterOpenAIApiKey => 'Enter your OpenAI API key';

  @override
  String get saveApiKey => 'Save API Key';

  @override
  String get apiKeyRequired => 'API key is required';

  @override
  String get settingsSaved => 'Settings saved';

  @override
  String get errorSavingSettings => 'Error saving settings';

  @override
  String get information => 'Information';

  @override
  String get summarySettingsInfo =>
      'OpenAI and Mistral AI provide fast and accurate summaries but require an internet connection and API key. Configure your preferred provider and customize the prompts used for summary generation.';

  @override
  String get generatingSummary => 'Generating summary...';

  @override
  String errorGeneratingSummary(String error) {
    return 'Error generating summary: $error';
  }

  @override
  String summaryForChapter(String title) {
    return 'Summary for $title';
  }

  @override
  String get noSummaryAvailable => 'No summary available';

  @override
  String get deleteBookConfirm =>
      'This will delete the book from the library. Are you sure?';

  @override
  String get confirm => 'Confirm';

  @override
  String get textSize => 'Text size';

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
  String get languageEnglish => 'English';

  @override
  String get languageFrench => 'French';

  @override
  String get summaryFromBeginning => 'From the Beginning';

  @override
  String get summarySinceLastTime => 'Last Reading';

  @override
  String get horizontalPaddingSaved =>
      'Horizontal padding saved. Changes will apply when you reopen a book.';

  @override
  String get verticalPaddingSaved =>
      'Vertical padding saved. Changes will apply when you reopen a book.';

  @override
  String get summaryCharacters => 'Characters';
}
