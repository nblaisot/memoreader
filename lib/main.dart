import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'screens/library_screen.dart';
import 'screens/routes.dart';
import 'screens/splash_screen.dart';
import 'services/settings_service.dart';
import 'services/background_summary_service.dart';
import 'services/sharing_service.dart';
import 'utils/app_colors.dart';
import 'utils/app_route_observer.dart';

import 'services/rag_indexing_service.dart';
import 'services/rag_database_service.dart';
import 'services/book_service.dart';
import 'models/rag_index_progress.dart';
import 'models/book.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();

  static MyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<MyAppState>()!;
}

class MyAppState extends State<MyApp> {
  final SettingsService _settingsService = SettingsService();
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    _loadLanguagePreference();
    // Initialize background summary service
    BackgroundSummaryService().initialize();
    // Initialize sharing service to handle "Open with" intents
    SharingService().initialize();
    // Auto-resume RAG indexing for any incomplete books
    _autoResumeRagIndexing();
  }
  
  /// Automatically resume RAG indexing for books with incomplete indexing
  /// This runs on app startup to continue where we left off
  Future<void> _autoResumeRagIndexing() async {
    try {
      final ragDbService = RagDatabaseService();
      final ragIndexingService = RagIndexingService();
      final bookService = BookService();
      
      // Get all books from library
      final books = await bookService.getAllBooks();
      
      // Check each book for incomplete indexing
      for (final book in books) {
        final status = await ragDbService.getIndexStatus(book.id);
        
        // Auto-resume if indexing was in progress or had errors
        if (status != null && 
            status.status == RagIndexStatus.indexing &&
            status.indexedChunks < status.totalChunks) {
          debugPrint('[RAG] Auto-resuming indexing for book: ${book.title} (${status.indexedChunks}/${status.totalChunks})');
          
          // Start indexing in background (non-blocking)
          // The service will pick up from the last checkpoint
          ragIndexingService.startIndexing(book.id).listen(
            (progress) {
              debugPrint('[RAG] Auto-resume progress for ${book.title}: ${progress.indexedChunks}/${progress.totalChunks}');
            },
            onError: (error) {
              debugPrint('[RAG] Auto-resume error for ${book.title}: $error');
            },
          );
        }
      }
    } catch (e) {
      debugPrint('[RAG] Error during auto-resume: $e');
      // Don't throw - this is non-critical background work
    }
  }

  Future<void> _loadLanguagePreference() async {
    final locale = await _settingsService.getSavedLanguage();
    setState(() {
      _locale = locale;
    });
  }

  void setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MemoReader',
      theme: ThemeData(
        colorScheme: AppColors.colorScheme,
        useMaterial3: true,
        primaryColor: AppColors.brainPink,
      ),
      navigatorObservers: [appRouteObserver],
      // Localization configuration
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'), // English - default
        Locale('fr'), // French
      ],
      // Use saved language preference or device locale
      locale: _locale,
      routes: {
        libraryRoute: (context) => const LibraryScreen(),
      },
      home: const SplashScreen(),
    );
  }
}
