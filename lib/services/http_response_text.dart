import 'dart:convert';

import 'package:http/http.dart' as http;

/// Decodes an HTTP response body as UTF-8.
///
/// The `http` package's [http.Response.body] defaults to Latin-1 when the
/// response omits a charset (common for Codex SSE). OpenAI/Codex payloads are
/// UTF-8, so accents and apostrophes become mojibake without this.
String decodeHttpResponseBody(http.Response response) {
  return utf8.decode(response.bodyBytes, allowMalformed: true);
}
