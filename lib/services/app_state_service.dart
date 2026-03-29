import 'package:shared_preferences/shared_preferences.dart';

/// Service responsible for storing transient application state that
/// needs to persist across launches, such as the last opened book.
class AppStateService {
  static const String _lastOpenedBookKey = 'last_opened_book_id';
  static const String _libraryViewModeKey = 'library_view_mode_is_list';
  static const String _libraryQuestionBookIdsKey = 'library_question_book_ids';
  static const String _readerQuestionBookIdsPrefix = 'reader_question_book_ids_';

  /// Save the identifier of the book that is currently being read.
  Future<void> setLastOpenedBook(String bookId) async {
    if (bookId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastOpenedBookKey, bookId);
  }

  /// Clear the stored last opened book information.
  Future<void> clearLastOpenedBook() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastOpenedBookKey);
  }

  /// Retrieve the identifier of the last opened book, if any.
  Future<String?> getLastOpenedBookId() async {
    final prefs = await SharedPreferences.getInstance();
    final bookId = prefs.getString(_lastOpenedBookKey);
    if (bookId == null || bookId.isEmpty) {
      return null;
    }
    return bookId;
  }

  /// Persist the preferred layout for the library screen.
  Future<void> setLibraryViewIsList(bool isListView) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_libraryViewModeKey, isListView);
  }

  /// Retrieve the preferred layout for the library screen.
  Future<bool> getLibraryViewIsList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_libraryViewModeKey) ?? false;
  }

  /// Save the selected book IDs for the library-context question screen.
  /// An empty list means "all books".
  Future<void> setLibraryQuestionBookIds(List<String> bookIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_libraryQuestionBookIdsKey, bookIds);
  }

  /// Retrieve the selected book IDs for the library-context question screen.
  /// Returns null if never set (use all books as default).
  Future<List<String>?> getLibraryQuestionBookIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_libraryQuestionBookIdsKey);
  }

  /// Save the selected book IDs for the reader-context question screen,
  /// keyed by the currently open book.
  Future<void> setReaderQuestionBookIds(String currentBookId, List<String> bookIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_readerQuestionBookIdsPrefix$currentBookId', bookIds);
  }

  /// Retrieve the selected book IDs for the reader-context question screen.
  /// Returns null if never set (use [currentBookId] only as default).
  Future<List<String>?> getReaderQuestionBookIds(String currentBookId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('$_readerQuestionBookIdsPrefix$currentBookId');
  }
}
