import 'package:shared_preferences/shared_preferences.dart';

/// Service responsible for storing transient application state that
/// needs to persist across launches, such as the last opened book.
class AppStateService {
  static const String _lastOpenedBookKey = 'last_opened_book_id';
  static const String _libraryViewModeKey = 'library_view_mode_is_list';

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
}
