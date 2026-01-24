import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _languageKey = 'selected_language';
  static const String _fontSizeKey = 'font_size';
  static const String _readerFontScaleKey = 'reader_font_scale';
  static const String _horizontalPaddingKey = 'horizontal_padding';
  static const String _verticalPaddingKey = 'vertical_padding';
  static const double _defaultFontSize = 18.0;
  static const double _minFontSize = 12.0;
  static const double _maxFontSize = 32.0;
  static const double _defaultHorizontalPadding = 30.0;
  static const double _defaultVerticalPadding = 50.0;
  static const double _minPadding = 0.0;
  static const double _maxPadding = 100.0;
  
  // RAG chunking configuration
  static const String _ragChunkMinTokensKey = 'rag_chunk_min_tokens';
  static const String _ragChunkMaxTokensKey = 'rag_chunk_max_tokens';
  static const String _ragChunkOverlapTokensKey = 'rag_chunk_overlap_tokens';
  static const int _defaultRagChunkMinTokens = 400; // Increased from 300
  static const int _defaultRagChunkMaxTokens = 1000; // Increased from 500 for better efficiency
  static const int _defaultRagChunkOverlapTokens = 100; // Increased from 50 for better context
  static const int _minRagChunkTokens = 50;
  static const int _maxRagChunkTokens = 2000;
  
  // RAG query configuration
  static const String _ragTopKKey = 'rag_top_k';
  static const int _defaultRagTopK = 10;
  static const int _minRagTopK = 1;
  static const int _maxRagTopK = 20;

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
  Future<void> saveLanguage(Locale? locale) async {
    final prefs = await SharedPreferences.getInstance();
    
    if (locale == null) {
      await prefs.remove(_languageKey);
    } else {
      await prefs.setString(_languageKey, locale.languageCode);
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

  /// Load the reader font scale multiplier (1.0 = normal, <1.0 = smaller, >1.0 = larger)
  /// Default is 1.0 (normal size)
  Future<double> getReaderFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    // Handle legacy values safely (could be int or double depending on app version)
    final raw = prefs.get(_readerFontScaleKey);

    // Migrate old int-based preset: -1 -> 0.9, 0 -> 1.0, 1 -> 1.1
    if (raw is int) {
      final scale = raw == -1 ? 0.9 : (raw == 1 ? 1.1 : 1.0);
      await prefs.setDouble(_readerFontScaleKey, scale);
      return scale;
    }

    if (raw is double) {
      // Clamp to current allowed range to avoid storing bad data
      final clamped = raw.clamp(0.5, 3.0);
      if (clamped != raw) {
        await prefs.setDouble(_readerFontScaleKey, clamped);
      }
      return clamped;
    }

    return 1.0;
  }

  /// Persist the reader font scale multiplier (clamped between 0.5 and 3.0)
  Future<void> saveReaderFontScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    final clampedScale = scale.clamp(0.5, 3.0);
    await prefs.setDouble(_readerFontScaleKey, clampedScale);
  }

  /// Get min font size
  double get minFontSize => _minFontSize;

  /// Get max font size
  double get maxFontSize => _maxFontSize;

  /// Get default font size
  double get defaultFontSize => _defaultFontSize;

  /// Get saved horizontal padding (default: 30.0 pixels)
  Future<double> getHorizontalPadding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_horizontalPaddingKey) ?? _defaultHorizontalPadding;
  }

  /// Save horizontal padding preference
  Future<void> saveHorizontalPadding(double padding) async {
    final prefs = await SharedPreferences.getInstance();
    // Clamp padding to valid range
    final clampedPadding = padding.clamp(_minPadding, _maxPadding);
    await prefs.setDouble(_horizontalPaddingKey, clampedPadding);
  }

  /// Get saved vertical padding (default: 50.0 pixels)
  Future<double> getVerticalPadding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_verticalPaddingKey) ?? _defaultVerticalPadding;
  }

  /// Save vertical padding preference
  Future<void> saveVerticalPadding(double padding) async {
    final prefs = await SharedPreferences.getInstance();
    // Clamp padding to valid range
    final clampedPadding = padding.clamp(_minPadding, _maxPadding);
    await prefs.setDouble(_verticalPaddingKey, clampedPadding);
  }

  /// Get min padding
  double get minPadding => _minPadding;

  /// Get max padding
  double get maxPadding => _maxPadding;

  /// Get default horizontal padding
  double get defaultHorizontalPadding => _defaultHorizontalPadding;

  /// Get default vertical padding
  double get defaultVerticalPadding => _defaultVerticalPadding;

  // RAG chunking configuration

  /// Get RAG chunk minimum tokens (default: 300)
  Future<int> getRagChunkMinTokens() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_ragChunkMinTokensKey) ?? _defaultRagChunkMinTokens;
  }

  /// Save RAG chunk minimum tokens
  Future<void> saveRagChunkMinTokens(int tokens) async {
    final prefs = await SharedPreferences.getInstance();
    final clamped = tokens.clamp(_minRagChunkTokens, _maxRagChunkTokens);
    await prefs.setInt(_ragChunkMinTokensKey, clamped);
  }

  /// Get RAG chunk maximum tokens (default: 500)
  Future<int> getRagChunkMaxTokens() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_ragChunkMaxTokensKey) ?? _defaultRagChunkMaxTokens;
  }

  /// Save RAG chunk maximum tokens
  Future<void> saveRagChunkMaxTokens(int tokens) async {
    final prefs = await SharedPreferences.getInstance();
    final clamped = tokens.clamp(_minRagChunkTokens, _maxRagChunkTokens);
    await prefs.setInt(_ragChunkMaxTokensKey, clamped);
  }

  /// Get RAG chunk overlap tokens (default: 50)
  Future<int> getRagChunkOverlapTokens() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_ragChunkOverlapTokensKey) ?? _defaultRagChunkOverlapTokens;
  }

  /// Save RAG chunk overlap tokens
  Future<void> saveRagChunkOverlapTokens(int tokens) async {
    final prefs = await SharedPreferences.getInstance();
    final clamped = tokens.clamp(0, _maxRagChunkTokens);
    await prefs.setInt(_ragChunkOverlapTokensKey, clamped);
  }

  /// Save RAG chunk configuration
  Future<void> saveRagChunkConfig({
    required int minTokens,
    required int maxTokens,
    required int overlapTokens,
  }) async {
    await Future.wait([
      saveRagChunkMinTokens(minTokens),
      saveRagChunkMaxTokens(maxTokens),
      saveRagChunkOverlapTokens(overlapTokens),
    ]);
  }

  /// Get default RAG chunk minimum tokens
  int get defaultRagChunkMinTokens => _defaultRagChunkMinTokens;

  /// Get default RAG chunk maximum tokens
  int get defaultRagChunkMaxTokens => _defaultRagChunkMaxTokens;

  /// Get default RAG chunk overlap tokens
  int get defaultRagChunkOverlapTokens => _defaultRagChunkOverlapTokens;

  /// Get minimum RAG chunk tokens
  int get minRagChunkTokens => _minRagChunkTokens;

  /// Get maximum RAG chunk tokens
  int get maxRagChunkTokens => _maxRagChunkTokens;

  // RAG query configuration

  /// Get RAG top-K chunks (default: 10)
  Future<int> getRagTopK() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_ragTopKKey) ?? _defaultRagTopK;
  }

  /// Save RAG top-K chunks
  Future<void> saveRagTopK(int value) async {
    final prefs = await SharedPreferences.getInstance();
    final clamped = value.clamp(_minRagTopK, _maxRagTopK);
    await prefs.setInt(_ragTopKKey, clamped);
  }

  /// Get default RAG top-K chunks
  int get defaultRagTopK => _defaultRagTopK;

  /// Get minimum RAG top-K chunks
  int get minRagTopK => _minRagTopK;

  /// Get maximum RAG top-K chunks
  int get maxRagTopK => _maxRagTopK;

  // RAG indexing performance configuration

  /// Get RAG batch size (default: 0 = auto-calculate based on provider)
  Future<int> getRagBatchSize() async {
    final prefs = await SharedPreferences.getInstance();
    // Default to a conservative batch size suitable for mobile / emulator.
    // 0 (auto) allows the indexing layer to choose a safe provider-based default.
    return prefs.getInt('rag_batch_size') ?? 0; // 0 = auto
  }

  /// Save RAG batch size (0 = auto-calculate)
  Future<void> saveRagBatchSize(int value) async {
    final prefs = await SharedPreferences.getInstance();
    // Clamp to a reasonable range to avoid excessive memory usage.
    await prefs.setInt('rag_batch_size', value.clamp(0, 2000));
  }

  /// Get RAG concurrent batches (default: 2 for mobile to reduce memory pressure)
  Future<int> getRagConcurrentBatches() async {
    final prefs = await SharedPreferences.getInstance();
    // Default to 2 for mobile devices to reduce memory usage and avoid OOM
    return prefs.getInt('rag_concurrent_batches') ?? 2;
  }

  /// Save RAG concurrent batches
  Future<void> saveRagConcurrentBatches(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('rag_concurrent_batches', value.clamp(1, 10));
  }

  /// Get RAG progress update frequency (default: 1 = every batch)
  Future<int> getRagProgressUpdateFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('rag_progress_update_frequency') ?? 1;
  }

  /// Save RAG progress update frequency
  Future<void> saveRagProgressUpdateFrequency(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('rag_progress_update_frequency', value.clamp(1, 100));
  }
}
