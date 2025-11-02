import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _languageKey = 'selected_language';
  static const String _fontSizeKey = 'font_size';
  static const double _defaultFontSize = 18.0;
  static const double _minFontSize = 12.0;
  static const double _maxFontSize = 32.0;

  /// Get the saved language preference
  Future<Locale?> getSavedLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final languageCode = prefs.getString(_languageKey);
    
    if (languageCode != null) {
      return Locale(languageCode);
    }
    return null; // null means use system default
  }

  /// Save language preference
  Future<void> saveLanguage(String? languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    
    if (languageCode == null) {
      await prefs.remove(_languageKey);
    } else {
      await prefs.setString(_languageKey, languageCode);
    }
  }

  /// Get current language code (null for system default)
  Future<String?> getLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languageKey);
  }

  /// Get saved font size (default: 18.0)
  Future<double> getFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_fontSizeKey) ?? _defaultFontSize;
  }

  /// Save font size preference
  Future<void> saveFontSize(double fontSize) async {
    final prefs = await SharedPreferences.getInstance();
    // Clamp font size to valid range
    final clampedSize = fontSize.clamp(_minFontSize, _maxFontSize);
    await prefs.setDouble(_fontSizeKey, clampedSize);
  }

  /// Get min font size
  double get minFontSize => _minFontSize;

  /// Get max font size
  double get maxFontSize => _maxFontSize;

  /// Get default font size
  double get defaultFontSize => _defaultFontSize;
}

