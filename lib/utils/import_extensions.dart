/// Supported file extensions for book import (EPUB, TXT, PDF).
const List<String> allowedBookImportExtensions = ['epub', 'txt', 'pdf'];

/// Returns true if [path] has an extension that is allowed for book import.
bool isAllowedBookImportPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.epub') ||
      lower.endsWith('.txt') ||
      lower.endsWith('.pdf');
}

/// Returns the lowercase extension (without dot) of [path], or empty string.
String extensionFromPath(String path) {
  final lastDot = path.toLowerCase().lastIndexOf('.');
  if (lastDot < 0 || lastDot == path.length - 1) return '';
  return path.toLowerCase().substring(lastDot + 1);
}
