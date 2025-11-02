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

  /// Font size setting label
  ///
  /// In en, this message translates to:
  /// **'Font Size'**
  String get fontSize;

  /// Font size setting description
  ///
  /// In en, this message translates to:
  /// **'Adjust the size of the text when reading'**
  String get fontSizeDescription;

  /// Example text shown in font size preview
  ///
  /// In en, this message translates to:
  /// **'This is an example of text size'**
  String get fontSizeExample;

  /// Text size label in reader menu
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

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

  /// OpenAI API key setting label
  ///
  /// In en, this message translates to:
  /// **'OpenAI API Key'**
  String get openaiApiKey;

  /// OpenAI API key setting description
  ///
  /// In en, this message translates to:
  /// **'Enter your OpenAI API key to enable AI-powered book summaries. Get your key at https://platform.openai.com/api-keys'**
  String get openaiApiKeyDescription;

  /// Message when API key is saved
  ///
  /// In en, this message translates to:
  /// **'API key saved successfully'**
  String get apiKeySaved;

  /// Loading message when generating summary
  ///
  /// In en, this message translates to:
  /// **'Generating summary...'**
  String get generatingSummary;

  /// Summary dialog title
  ///
  /// In en, this message translates to:
  /// **'Summary up to your current position'**
  String get summaryUpToPosition;

  /// Error message when summary generation fails
  ///
  /// In en, this message translates to:
  /// **'Error generating summary: {error}'**
  String errorGeneratingSummary(String error);

  /// Error when API key is not set
  ///
  /// In en, this message translates to:
  /// **'OpenAI API key not configured. Please set it in settings.'**
  String get apiKeyNotConfigured;

  /// Dialog title for entering API key
  ///
  /// In en, this message translates to:
  /// **'Enter OpenAI API Key'**
  String get enterApiKey;

  /// Save button label
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Summary type option - from beginning
  ///
  /// In en, this message translates to:
  /// **'Summary from the beginning'**
  String get summaryFromBeginning;

  /// Summary type option - since last time
  ///
  /// In en, this message translates to:
  /// **'Summary since last time'**
  String get summarySinceLastTime;

  /// Summary type option - characters
  ///
  /// In en, this message translates to:
  /// **'Characters'**
  String get summaryCharacters;

  /// Important Words menu item
  ///
  /// In en, this message translates to:
  /// **'Important Words'**
  String get importantWords;

  /// Loading message when generating important words
  ///
  /// In en, this message translates to:
  /// **'Generating important words...'**
  String get generatingImportantWords;

  /// Error message when loading important words fails
  ///
  /// In en, this message translates to:
  /// **'Error loading important words: {error}'**
  String errorLoadingImportantWords(String error);

  /// Link text to explain what API key is
  ///
  /// In en, this message translates to:
  /// **'What is that?'**
  String get whatIsApiKey;

  /// Explanation of what an API key is and how to get it
  ///
  /// In en, this message translates to:
  /// **'An OpenAI API key is required to use the AI-powered features like automatic summaries and important words. You can get your API key from OpenAI\'s platform. After creating an account, go to API Keys section and create a new key. Keep it secure and never share it publicly.'**
  String get apiKeyExplanation;

  /// Button text to open OpenAI website
  ///
  /// In en, this message translates to:
  /// **'Get API Key from OpenAI'**
  String get getApiKeyFromOpenAI;

  /// Information about typical API costs
  ///
  /// In en, this message translates to:
  /// **'Typical costs: For an average novel like Lord of the Flies, generating summaries costs approximately 10-50 cents (USD) for the entire book.'**
  String get apiKeyCostInfo;

  /// Label for API cost display
  ///
  /// In en, this message translates to:
  /// **'Estimated API Cost'**
  String get apiCostLabel;

  /// Description of API cost tracking
  ///
  /// In en, this message translates to:
  /// **'This shows the cumulative cost of all API calls made in this app. Costs are calculated based on actual token usage from OpenAI responses.'**
  String get apiCostDescription;

  /// Button text to reset API cost counter
  ///
  /// In en, this message translates to:
  /// **'Reset Cost Counter'**
  String get resetApiCost;

  /// Message shown when API cost counter is reset
  ///
  /// In en, this message translates to:
  /// **'API cost counter has been reset.'**
  String get apiCostReset;

  /// Next button label
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// Close button label
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;
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
