import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fr'),
  ];

  /// The application title
  ///
  /// In en, this message translates to:
  /// **'MemoReader'**
  String get appTitle;

  /// Library screen title
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get library;

  /// Import EPUB button label
  ///
  /// In en, this message translates to:
  /// **'Import EPUB'**
  String get importEpub;

  /// Importing state label
  ///
  /// In en, this message translates to:
  /// **'Importing...'**
  String get importing;

  /// Importing EPUB message
  ///
  /// In en, this message translates to:
  /// **'Importing EPUB...'**
  String get importingEpub;

  /// Success message after importing a book
  ///
  /// In en, this message translates to:
  /// **'Book imported successfully!'**
  String get bookImportedSuccessfully;

  /// Error message when importing fails
  ///
  /// In en, this message translates to:
  /// **'Error importing book: {error}'**
  String errorImportingBook(String error);

  /// Error message when loading books fails
  ///
  /// In en, this message translates to:
  /// **'Error loading books: {error}'**
  String errorLoadingBooks(String error);

  /// Message when library is empty
  ///
  /// In en, this message translates to:
  /// **'No books in your library'**
  String get noBooksInLibrary;

  /// Instruction for importing EPUB
  ///
  /// In en, this message translates to:
  /// **'Tap the + button to import an EPUB'**
  String get tapToImportEpub;

  /// Delete book dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Book'**
  String get deleteBook;

  /// Delete confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{title}\"?'**
  String confirmDeleteBook(String title);

  /// Cancel button label
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Delete button label
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Message after book deletion
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" deleted'**
  String bookDeleted(String title);

  /// Error message when deletion fails
  ///
  /// In en, this message translates to:
  /// **'Error deleting book: {error}'**
  String errorDeletingBook(String error);

  /// Refresh button tooltip
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// Tooltip for switching to the grid view
  ///
  /// In en, this message translates to:
  /// **'Grid view'**
  String get libraryShowGrid;

  /// Tooltip for switching to the list view
  ///
  /// In en, this message translates to:
  /// **'List view'**
  String get libraryShowList;

  /// Retry button label
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Chapters menu item
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get chapters;

  /// Table of contents menu item
  ///
  /// In en, this message translates to:
  /// **'Table of Contents'**
  String get tableOfContents;

  /// Chapter label with number
  ///
  /// In en, this message translates to:
  /// **'Chapter {number}'**
  String chapter(int number);

  /// Go to page menu item
  ///
  /// In en, this message translates to:
  /// **'Go to Page'**
  String get goToPage;

  /// Go to a percentage of the book
  ///
  /// In en, this message translates to:
  /// **'Go to % progress'**
  String get goToPercentage;

  /// Prompt label for percentage input
  ///
  /// In en, this message translates to:
  /// **'Enter progress percentage (0-100)'**
  String get enterPercentage;

  /// Error message when percentage input is invalid
  ///
  /// In en, this message translates to:
  /// **'Please enter a value between 0 and 100'**
  String get invalidPercentage;

  /// Summary menu item
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get summary;

  /// Back to library menu item
  ///
  /// In en, this message translates to:
  /// **'Back to Library'**
  String get backToLibrary;

  /// Page number input helper
  ///
  /// In en, this message translates to:
  /// **'Enter page number (1-{max})'**
  String enterPageNumber(int max);

  /// Page label
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get page;

  /// Go button label
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get go;

  /// Invalid page number error
  ///
  /// In en, this message translates to:
  /// **'Please enter a page number between 1 and {max}'**
  String invalidPageNumber(int max);

  /// No pages error message
  ///
  /// In en, this message translates to:
  /// **'No pages available'**
  String get noPagesAvailable;

  /// No chapters error message
  ///
  /// In en, this message translates to:
  /// **'No chapters available'**
  String get noChaptersAvailable;

  /// Menu item to reset summaries
  ///
  /// In en, this message translates to:
  /// **'Reset summaries'**
  String get resetSummaries;

  /// Message displayed when summaries are reset
  ///
  /// In en, this message translates to:
  /// **'Summaries reset'**
  String get summariesReset;

  /// Error message when reset fails
  ///
  /// In en, this message translates to:
  /// **'Unable to reset summaries. Please try again.'**
  String get resetSummariesError;

  /// Summary feature placeholder message
  ///
  /// In en, this message translates to:
  /// **'Summary feature will be implemented later with LLM integration.'**
  String get summaryFeatureComingSoon;

  /// OK button label
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// Error message when loading book fails
  ///
  /// In en, this message translates to:
  /// **'Error loading book: {error}'**
  String errorLoadingBook(String error);

  /// Loading book message
  ///
  /// In en, this message translates to:
  /// **'Loading {title}...'**
  String loadingBook(String title);

  /// Error loading book screen title
  ///
  /// In en, this message translates to:
  /// **'Error Loading Book'**
  String get errorLoadingBookTitle;

  /// No content available message
  ///
  /// In en, this message translates to:
  /// **'No content available in this book.'**
  String get noContentAvailable;

  /// End of book message
  ///
  /// In en, this message translates to:
  /// **'End of book reached'**
  String get endOfBookReached;

  /// Beginning of book message
  ///
  /// In en, this message translates to:
  /// **'Beginning of book'**
  String get beginningOfBook;

  /// Invalid chapter index error
  ///
  /// In en, this message translates to:
  /// **'Invalid chapter index'**
  String get invalidChapterIndex;

  /// Error loading chapter message
  ///
  /// In en, this message translates to:
  /// **'Error loading chapter: {error}'**
  String errorLoadingChapter(String error);

  /// Chapter information
  ///
  /// In en, this message translates to:
  /// **'Chapter {current}/{total}'**
  String chapterInfo(int current, int total);

  /// Page information
  ///
  /// In en, this message translates to:
  /// **'Page {current}/{total}'**
  String pageInfo(int current, int total);

  /// Chapter page count message
  ///
  /// In en, this message translates to:
  /// **'This chapter has {count} page'**
  String thisChapterHasPages(Object count);

  /// Chapter page count message (plural)
  ///
  /// In en, this message translates to:
  /// **'This chapter has {count} pages'**
  String thisChapterHasPages_plural(Object count);

  /// Settings screen title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// Summary provider section title
  ///
  /// In en, this message translates to:
  /// **'Summary Provider'**
  String get summaryProvider;

  /// Summary provider section description
  ///
  /// In en, this message translates to:
  /// **'Choose how summaries are generated'**
  String get summaryProviderDescription;

  /// Message shown when summary provider is not configured
  ///
  /// In en, this message translates to:
  /// **'Configure a summary provider in Settings to generate summaries.'**
  String get summaryProviderMissing;

  /// Prompt settings section title
  ///
  /// In en, this message translates to:
  /// **'Prompt Settings'**
  String get promptSettings;

  /// Description of prompt settings
  ///
  /// In en, this message translates to:
  /// **'Customize the prompts used for summary generation. You can use placeholders in your prompts: text (for the text to summarize), bookTitle (for the book title), and chapterTitle (for the chapter title). Write them with curly braces in your prompts.'**
  String get promptSettingsDescription;

  /// Section title for configuring the reader selection action
  ///
  /// In en, this message translates to:
  /// **'Text selection action'**
  String get textSelectionActionSettings;

  /// Description for the reader selection action section
  ///
  /// In en, this message translates to:
  /// **'Customize the action displayed when selecting text. You can use {text} for the selected text and {language} for the application language.'**
  String textSelectionActionDescription(Object language, Object text);

  /// Label for the French selection action name
  ///
  /// In en, this message translates to:
  /// **'Action label (French)'**
  String get textSelectionActionLabelFr;

  /// Label for the English selection action name
  ///
  /// In en, this message translates to:
  /// **'Action label (English)'**
  String get textSelectionActionLabelEn;

  /// Editor label for the French selection action prompt
  ///
  /// In en, this message translates to:
  /// **'Action prompt (French)'**
  String get textSelectionActionPromptFr;

  /// Editor label for the English selection action prompt
  ///
  /// In en, this message translates to:
  /// **'Action prompt (English)'**
  String get textSelectionActionPromptEn;

  /// Message shown while the selection action is running
  ///
  /// In en, this message translates to:
  /// **'Processing selection...'**
  String get textSelectionActionProcessing;

  /// Error message when the selection action fails
  ///
  /// In en, this message translates to:
  /// **'Unable to process the selected text.'**
  String get textSelectionActionError;

  /// Label shown above the selected text in the action dialog
  ///
  /// In en, this message translates to:
  /// **'Selected text'**
  String get textSelectionSelectedTextLabel;

  /// Label shown above the generated response in the action dialog
  ///
  /// In en, this message translates to:
  /// **'Response'**
  String get textSelectionActionResultLabel;

  /// Default label for the selection action button
  ///
  /// In en, this message translates to:
  /// **'Translate'**
  String get textSelectionDefaultLabel;

  /// Dialog title when summary service is missing
  ///
  /// In en, this message translates to:
  /// **'Configuration required'**
  String get summaryConfigurationRequiredTitle;

  /// Dialog body when summary service is missing
  ///
  /// In en, this message translates to:
  /// **'To use this feature you need to configure an AI provider in the settings. Would you like to open the settings now?'**
  String get summaryConfigurationRequiredBody;

  /// Display name of the current language
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get appLanguageName;

  /// Label for chunk summary prompt
  ///
  /// In en, this message translates to:
  /// **'Chunk Summary Prompt'**
  String get chunkSummaryPrompt;

  /// Label for French chunk summary prompt
  ///
  /// In en, this message translates to:
  /// **'Chunk Summary Prompt (French)'**
  String get chunkSummaryPromptFr;

  /// Label for English chunk summary prompt
  ///
  /// In en, this message translates to:
  /// **'Chunk Summary Prompt (English)'**
  String get chunkSummaryPromptEn;

  /// Label for character extraction prompt
  ///
  /// In en, this message translates to:
  /// **'Character Extraction Prompt'**
  String get characterExtractionPrompt;

  /// Label for French character extraction prompt
  ///
  /// In en, this message translates to:
  /// **'Character Extraction Prompt (French)'**
  String get characterExtractionPromptFr;

  /// Label for English character extraction prompt
  ///
  /// In en, this message translates to:
  /// **'Character Extraction Prompt (English)'**
  String get characterExtractionPromptEn;

  /// Label for batch summary prompt
  ///
  /// In en, this message translates to:
  /// **'Batch Summary Prompt'**
  String get batchSummaryPrompt;

  /// Label for French batch summary prompt
  ///
  /// In en, this message translates to:
  /// **'Batch Summary Prompt (French)'**
  String get batchSummaryPromptFr;

  /// Label for English batch summary prompt
  ///
  /// In en, this message translates to:
  /// **'Batch Summary Prompt (English)'**
  String get batchSummaryPromptEn;

  /// Label for narrative synthesis prompt
  ///
  /// In en, this message translates to:
  /// **'Narrative Synthesis Prompt'**
  String get narrativeSynthesisPrompt;

  /// Label for French narrative synthesis prompt
  ///
  /// In en, this message translates to:
  /// **'Narrative Synthesis Prompt (French)'**
  String get narrativeSynthesisPromptFr;

  /// Label for English narrative synthesis prompt
  ///
  /// In en, this message translates to:
  /// **'Narrative Synthesis Prompt (English)'**
  String get narrativeSynthesisPromptEn;

  /// Label for fallback summary prompt
  ///
  /// In en, this message translates to:
  /// **'Fallback Summary Prompt'**
  String get fallbackSummaryPrompt;

  /// Label for French fallback summary prompt
  ///
  /// In en, this message translates to:
  /// **'Fallback Summary Prompt (French)'**
  String get fallbackSummaryPromptFr;

  /// Label for English fallback summary prompt
  ///
  /// In en, this message translates to:
  /// **'Fallback Summary Prompt (English)'**
  String get fallbackSummaryPromptEn;

  /// Label for concise summary prompt
  ///
  /// In en, this message translates to:
  /// **'Concise Summary Prompt'**
  String get conciseSummaryPrompt;

  /// Label for French concise summary prompt
  ///
  /// In en, this message translates to:
  /// **'Concise Summary Prompt (French)'**
  String get conciseSummaryPromptFr;

  /// Label for English concise summary prompt
  ///
  /// In en, this message translates to:
  /// **'Concise Summary Prompt (English)'**
  String get conciseSummaryPromptEn;

  /// Button to reset prompts to default
  ///
  /// In en, this message translates to:
  /// **'Reset to Default'**
  String get resetPrompts;

  /// Message when prompts are reset
  ///
  /// In en, this message translates to:
  /// **'Prompts reset to default values'**
  String get promptsReset;

  /// Message when a prompt is saved
  ///
  /// In en, this message translates to:
  /// **'Prompt saved'**
  String get promptSaved;

  /// OpenAI model option
  ///
  /// In en, this message translates to:
  /// **'OpenAI (GPT)'**
  String get openAIModel;

  /// OpenAI model configured message
  ///
  /// In en, this message translates to:
  /// **'Configured - Requires internet'**
  String get openAIModelConfigured;

  /// OpenAI model not configured message
  ///
  /// In en, this message translates to:
  /// **'Not configured - API key required'**
  String get openAIModelNotConfigured;

  /// OpenAI settings section title
  ///
  /// In en, this message translates to:
  /// **'OpenAI Settings'**
  String get openAISettings;

  /// OpenAI settings section description
  ///
  /// In en, this message translates to:
  /// **'Enter your OpenAI API key to use GPT for summaries'**
  String get openAISettingsDescription;

  /// OpenAI API key label
  ///
  /// In en, this message translates to:
  /// **'OpenAI API Key'**
  String get openAIApiKey;

  /// OpenAI API key input hint
  ///
  /// In en, this message translates to:
  /// **'Enter your OpenAI API key'**
  String get enterOpenAIApiKey;

  /// Save API key button label
  ///
  /// In en, this message translates to:
  /// **'Save API Key'**
  String get saveApiKey;

  /// API key required error message
  ///
  /// In en, this message translates to:
  /// **'API key is required'**
  String get apiKeyRequired;

  /// Settings saved confirmation message
  ///
  /// In en, this message translates to:
  /// **'Settings saved'**
  String get settingsSaved;

  /// Error saving settings message
  ///
  /// In en, this message translates to:
  /// **'Error saving settings'**
  String get errorSavingSettings;

  /// Information section title
  ///
  /// In en, this message translates to:
  /// **'Information'**
  String get information;

  /// Summary settings information text
  ///
  /// In en, this message translates to:
  /// **'OpenAI and Mistral AI provide fast and accurate summaries but require an internet connection and API key. Configure your preferred provider and customize the prompts used for summary generation.'**
  String get summarySettingsInfo;

  /// Generating summary message
  ///
  /// In en, this message translates to:
  /// **'Generating summary...'**
  String get generatingSummary;

  /// Error generating summary message
  ///
  /// In en, this message translates to:
  /// **'Error generating summary: {error}'**
  String errorGeneratingSummary(String error);

  /// Summary dialog title
  ///
  /// In en, this message translates to:
  /// **'Summary for {title}'**
  String summaryForChapter(String title);

  /// No summary available message
  ///
  /// In en, this message translates to:
  /// **'No summary available'**
  String get noSummaryAvailable;

  /// Confirmation message when deleting a book
  ///
  /// In en, this message translates to:
  /// **'This will delete the book from the library. Are you sure?'**
  String get deleteBookConfirm;

  /// Confirm button label
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// Text size label in reader menu
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

  /// Language setting label
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// Language setting description
  ///
  /// In en, this message translates to:
  /// **'Choose your preferred language. Changes require app restart.'**
  String get languageDescription;

  /// System default language option
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get languageSystemDefault;

  /// System default language description
  ///
  /// In en, this message translates to:
  /// **'Use device language settings'**
  String get languageSystemDefaultDescription;

  /// Message shown when language is changed
  ///
  /// In en, this message translates to:
  /// **'Language preference saved. Please restart the app for changes to take effect.'**
  String get languageChangedRestart;

  /// English language option
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// French language option
  ///
  /// In en, this message translates to:
  /// **'French'**
  String get languageFrench;

  /// Summary type option - from beginning
  ///
  /// In en, this message translates to:
  /// **'From the Beginning'**
  String get summaryFromBeginning;

  /// Summary type option - since last time
  ///
  /// In en, this message translates to:
  /// **'Last Reading'**
  String get summarySinceLastTime;

  /// Message shown when horizontal padding is saved
  ///
  /// In en, this message translates to:
  /// **'Horizontal padding saved. Changes will apply when you reopen a book.'**
  String get horizontalPaddingSaved;

  /// Message shown when vertical padding is saved
  ///
  /// In en, this message translates to:
  /// **'Vertical padding saved. Changes will apply when you reopen a book.'**
  String get verticalPaddingSaved;

  /// Summary type option - characters
  ///
  /// In en, this message translates to:
  /// **'Characters'**
  String get summaryCharacters;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fr':
      return AppLocalizationsFr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
