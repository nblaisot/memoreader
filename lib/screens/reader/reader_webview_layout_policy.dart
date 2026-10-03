/// Selects the character anchor to preserve while the WebView changes layout.
///
/// Explicit navigation targets take precedence; otherwise the current page's
/// first character is retained. Character offsets cannot be negative.
int resolveWebViewLayoutAnchor({
  required int currentPageStart,
  int? requestedCharacter,
}) {
  final anchor = requestedCharacter ?? currentPageStart;
  return anchor < 0 ? 0 : anchor;
}
