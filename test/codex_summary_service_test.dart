import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memoreader/services/codex_auth_service.dart';
import 'package:memoreader/services/codex_summary_service.dart';

void main() {
  test('generateSummary parses SSE response', () async {
    String? stored = jsonEncode({
      'access_token': 'token_abc',
      'refresh_token': 'refresh',
      'expires_at_ms': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'account_id': 'acct_1',
    });

    final client = MockClient((request) async {
      expect(request.url.host, 'chatgpt.com');
      expect(request.headers['Authorization'], 'Bearer token_abc');
      expect(request.headers['ChatGPT-Account-Id'], 'acct_1');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-5.6-terra');

      const sse = '''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Summary text"}

''';
      return http.Response(
        sse,
        200,
        headers: {'Content-Type': 'text/event-stream'},
      );
    });

    final auth = CodexAuthService(
      httpClient: client,
      readStoredJson: () async => stored,
      writeStoredJson: (v) async => stored = v,
      deleteStoredJson: () async => stored = null,
    );

    final svc = CodexSummaryService(authService: auth, httpClient: client);
    final out = await svc.generateSummary('prompt', 'en');
    expect(out, 'Summary text');
  });

  test('generateSummary decodes UTF-8 accents from SSE body bytes', () async {
    String? stored = jsonEncode({
      'access_token': 'token_abc',
      'refresh_token': 'refresh',
      'expires_at_ms': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    });

    const french = "C'était de sa faute si Sirius était mort";
    final sseBytes = utf8.encode('''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Translation: $french"}

''');

    final client = MockClient((request) async {
      return http.Response.bytes(
        sseBytes,
        200,
        headers: {'Content-Type': 'text/event-stream'},
      );
    });

    final auth = CodexAuthService(
      httpClient: client,
      readStoredJson: () async => stored,
    );

    final svc = CodexSummaryService(authService: auth, httpClient: client);
    final out = await svc.generateSummary('prompt', 'fr');
    expect(out, contains("C'était"));
    expect(out, isNot(contains('Ã')));
  });

  test('generateSummary throws when not signed in', () async {
    final auth = CodexAuthService(
      httpClient: MockClient((_) async => http.Response('', 500)),
      readStoredJson: () async => null,
    );
    final svc = CodexSummaryService(authService: auth);
    expect(
      () => svc.generateSummary('p', 'en'),
      throwsA(isA<CodexAuthException>()),
    );
  });
}
