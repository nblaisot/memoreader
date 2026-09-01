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
import 'services/google_drive_sync_service.dart';
import 'widgets/compact_error_snack_bar.dart';

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

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final SettingsService _settingsService = SettingsService();
  final GoogleDriveSyncService _syncService = GoogleDriveSyncService();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncService.syncStatus.addListener(_onSyncStatusChanged);
    _loadLanguagePreference();
    BackgroundSummaryService().initialize();
    SharingService().initialize();
    _autoResumeRagIndexing();
    _startDriveSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncService.syncStatus.removeListener(_onSyncStatusChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startDriveSync();
    }
  }

  void _onSyncStatusChanged() {
    final state = _syncService.syncStatus.value;
    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null || !shouldNotifyForSyncState(state)) return;

    switch (state.status) {
      case SyncStatus.error:
        showCompactErrorSnackBar(
          messenger,
          AppLocalizations.of(messenger.context)?.driveSyncCompactError ??
              'Google Drive sync failed',
        );
        break;
      case SyncStatus.syncing:
      case SyncStatus.success:
      case SyncStatus.idle:
        break;
    }
  }

  Future<void> _startDriveSync() async {
    try {
      await _syncService.syncOnStartup();
    } catch (e) {
      debugPrint('[Main] Failed to start drive sync: $e');
    }
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

        // Resume every non-complete state after credentials/config may change.
        if (status == null || !status.isComplete) {
          debugPrint(
            '[RAG] Auto-resuming indexing for book: ${book.title} (${status?.indexedChunks ?? 0}/${status?.totalChunks ?? 0})',
          );

          // Start indexing in background (non-blocking)
          // The service will pick up from the last checkpoint
          ragIndexingService
              .startIndexing(book.id)
              .listen(
                (progress) {
                  debugPrint(
                    '[RAG] Auto-resume progress for ${book.title}: ${progress.indexedChunks}/${progress.totalChunks}',
                  );
                },
                onError: (error) {
                  debugPrint(
                    '[RAG] Auto-resume error for ${book.title}: $error',
                  );
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
      scaffoldMessengerKey: _scaffoldMessengerKey,
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
      routes: {libraryRoute: (context) => const LibraryScreen()},
      home: const SplashScreen(),
    );
  }
}
