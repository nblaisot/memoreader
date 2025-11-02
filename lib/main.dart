import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:memoreader/l10n/app_localizations.dart';
import 'screens/splash_screen.dart';
import 'services/settings_service.dart';
import 'utils/app_colors.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_MyAppState>()!;
}

class _MyAppState extends State<MyApp> {
  final SettingsService _settingsService = SettingsService();
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    _loadLanguagePreference();
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
      title: 'MemoReader',
      theme: ThemeData(
        colorScheme: AppColors.colorScheme,
        useMaterial3: true,
        primaryColor: AppColors.brainPink,
      ),
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
      home: const SplashScreen(),
    );
  }
}
