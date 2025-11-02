import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epubx/epubx.dart';
import 'package:intl/intl.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/book_summary_cache.dart';
import 'summary_database_service.dart';
import 'book_service.dart';
import 'settings_service.dart';
import 'api_cost_service.dart';

class ImportantWordsService {
  final SummaryDatabaseService _dbService = SummaryDatabaseService();
  final BookService _bookService = BookService();
  final SettingsService _settingsService = SettingsService();
  final ApiCostService _costService = ApiCostService();

  // OpenAI API configuration
  static const String _apiUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o-mini';

  Future<String?> _getStoredApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('openai_api_key');
    } catch (e) {
      debugPrint('Error getting API key: $e');
      return null;
    }
  }

  /// Extract plain text from HTML content
  String _extractTextFromHtml(String htmlContent) {
    try {
      final document = html_parser.parse(htmlContent);
      return document.body?.text ?? '';
    } catch (e) {
      debugPrint('Error parsing HTML: $e');
      // Fallback: remove HTML tags using regex
      return htmlContent
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
  }

  /// Get all text from all chapters of the book
  Future<String> _getAllBookText(Book book) async {
    try {
      final epub = await _bookService.loadEpubBook(book.filePath);
      final chapters = _parseChapters(epub);
      
      final allText = StringBuffer();
      for (final chapter in chapters) {
        final plainText = _extractTextFromHtml(chapter.htmlContent);
        allText.write(plainText);
        allText.write(' ');
      }
      
      return allText.toString();
    } catch (e) {
      debugPrint('Error getting all book text: $e');
      rethrow;
    }
  }

  /// Parse chapters from EPUB book
  List<Chapter> _parseChapters(EpubBook epubBook) {
    final chapters = <Chapter>[];

    try {
      final epubChapters = epubBook.Chapters;
      if (epubChapters == null || epubChapters.isEmpty) {
        return chapters;
      }

      for (int i = 0; i < epubChapters.length; i++) {
        try {
          final epubChapter = epubChapters[i];
          final title = epubChapter.Title?.isNotEmpty == true
              ? epubChapter.Title!
              : 'Chapter ${i + 1}';
          final htmlContent = epubChapter.HtmlContent ?? '';

          if (htmlContent.isNotEmpty) {
            chapters.add(Chapter(
              index: i,
              title: title,
              htmlContent: htmlContent,
            ));
          }
        } catch (e) {
          debugPrint('Error parsing chapter $i: $e');
        }
      }
    } catch (e) {
      debugPrint('Error parsing chapters: $e');
    }

    return chapters;
  }

  /// Count word occurrences in text
  Map<String, int> _countWordOccurrences(String text) {
    // Remove punctuation and split by whitespace
    final cleanedText = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    
    final words = cleanedText.split(' ').where((w) => w.isNotEmpty).toList();
    final wordCount = <String, int>{};
    
    for (final word in words) {
      wordCount[word] = (wordCount[word] ?? 0) + 1;
    }
    
    return wordCount;
  }

  /// Get native language from app settings or system locale
  Future<String> _getNativeLanguage() async {
    try {
      // Get saved language preference from settings
      final languageCode = await _settingsService.getLanguageCode();
      
      if (languageCode != null) {
        return languageCode == 'fr' ? 'French' : 'English';
      }
      
      // Fall back to system locale
      final locale = Intl.systemLocale;
      if (locale.startsWith('fr')) {
        return 'French';
      }
      return 'English'; // Default to English
    } catch (e) {
      return 'English';
    }
  }

  /// Generate important words table using LLM
  Future<String> _generateImportantWordsTable(
    Map<String, int> wordOccurrences,
    String bookTitle,
  ) async {
    final apiKey = await _getStoredApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('OpenAI API key not configured. Please set it in settings.');
    }

    // Sort words by occurrence count (descending)
    final sortedWords = wordOccurrences.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    // Create list of words with occurrences
    final wordList = sortedWords.map((e) => '${e.key}: ${e.value}').join('\n');
    
    final nativeLanguage = await _getNativeLanguage();
    
    final prompt = '''Analyze the following list of words from a book, sorted by occurrence frequency. 

For each word:
1. If the original language is Mandarin Chinese, provide the pinyin pronunciation in the second column
2. For all other languages, provide the pronunciation using IPA (International Phonetic Alphabet) or phonetic spelling in the second column
3. Provide the translation to $nativeLanguage in the third column

Format the output as a markdown table with three columns:
- Column 1: Word (ordered by occurrence frequency, highest first)
- Column 2: Pronunciation (pinyin for Mandarin, IPA/phonetic for others)
- Column 3: Translation to $nativeLanguage

Start with the most frequently occurring words.

Book Title: $bookTitle

Word List (word: occurrence_count):
$wordList

Important Words Table:''';

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.3,
          'max_tokens': 4000, // Enough for a comprehensive word table
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Track API costs
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final promptTokens = usage['prompt_tokens'] as int? ?? 0;
          final completionTokens = usage['completion_tokens'] as int? ?? 0;
          await _costService.addCost(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
          );
        }
        
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null && content.isNotEmpty) {
          return content.trim();
        } else {
          throw Exception('Empty response from OpenAI API');
        }
      } else {
        final errorData = jsonDecode(response.body) as Map<String, dynamic>;
        final errorMessage = errorData['error']?['message'] ?? 'Unknown error';
        throw Exception('OpenAI API error: $errorMessage');
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to generate important words table: $e');
    }
  }

  /// Get or generate important words for a book
  Future<String> getImportantWords(Book book) async {
    try {
      // Check if we have cached important words
      final cache = await _dbService.getSummaryCache(book.id);
      if (cache != null && cache.importantWords != null) {
        // Return cached important words
        debugPrint('Returning cached important words');
        return cache.importantWords!;
      }

      // Generate important words
      debugPrint('Generating important words for book: ${book.title}');
      
      // Get all text from the book
      final allText = await _getAllBookText(book);
      if (allText.isEmpty) {
        throw Exception('No text content found in book');
      }

      // Count word occurrences
      final wordOccurrences = _countWordOccurrences(allText);
      debugPrint('Found ${wordOccurrences.length} unique words');

      // Generate important words table using LLM
      final importantWordsTable = await _generateImportantWordsTable(
        wordOccurrences,
        book.title,
      );

      // Cache the result
      if (cache != null) {
        final updatedCache = cache.copyWith(
          importantWords: importantWordsTable,
        );
        await _dbService.saveSummaryCache(updatedCache);
      } else {
        // Create new cache with important words
        final newCache = BookSummaryCache(
          bookId: book.id,
          lastProcessedChunkIndex: -1,
          cumulativeSummary: '',
          lastUpdated: DateTime.now(),
          importantWords: importantWordsTable,
        );
        await _dbService.saveSummaryCache(newCache);
      }

      return importantWordsTable;
    } catch (e) {
      debugPrint('Error generating important words: $e');
      rethrow;
    }
  }
}

