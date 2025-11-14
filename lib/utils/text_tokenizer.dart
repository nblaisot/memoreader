/// Utilities for tokenizing text in a way that preserves whitespace between
/// tokens. The pagination engine and summary services rely on the same
/// tokenization logic so that reading progress can be translated accurately
/// between rendered pages and summary extraction.

final RegExp _tokenRegex = RegExp(r'\S+|\s+');

/// Tokenize [text] into a list of strings while keeping whitespace tokens.
List<String> tokenizePreservingWhitespace(String text) {
  return _tokenRegex.allMatches(text).map((match) => match.group(0)!).toList();
}

/// Represents a token along with its [start] (inclusive) and [end] (exclusive)
/// character offsets within the original string.
class TokenSpan {
  const TokenSpan({required this.text, required this.start, required this.end});

  final String text;
  final int start;
  final int end;

  int get length => end - start;
}

/// Tokenize [text] while also returning the character range of each token.
List<TokenSpan> tokenizeWithSpans(String text) {
  return _tokenRegex.allMatches(text).map((match) {
    final tokenText = match.group(0) ?? '';
    return TokenSpan(text: tokenText, start: match.start, end: match.end);
  }).toList();
}

