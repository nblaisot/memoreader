import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/screens/reader/reader_webview_layout_policy.dart';

void main() {
  test('layout changes retain the first character on the current page', () {
    expect(resolveWebViewLayoutAnchor(currentPageStart: 842), 842);
  });

  test(
    'an explicit navigation anchor takes precedence over the current page',
    () {
      expect(
        resolveWebViewLayoutAnchor(
          currentPageStart: 842,
          requestedCharacter: 1200,
        ),
        1200,
      );
    },
  );

  test('consecutive layout requests use the latest explicit anchor', () {
    var currentPageStart = 842;
    currentPageStart = resolveWebViewLayoutAnchor(
      currentPageStart: currentPageStart,
      requestedCharacter: 1200,
    );
    currentPageStart = resolveWebViewLayoutAnchor(
      currentPageStart: currentPageStart,
      requestedCharacter: 615,
    );

    expect(currentPageStart, 615);
  });

  test('negative anchors are clamped to the start of the book', () {
    expect(
      resolveWebViewLayoutAnchor(currentPageStart: 842, requestedCharacter: -1),
      0,
    );
  });
}
