import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memoreader/services/codex_auth_service.dart';
import 'package:memoreader/services/codex_embedding_service.dart';
import 'package:memoreader/services/rag_embedding_service.dart';

void main() {
  test('embedTexts posts to OpenAI embeddings with Codex bearer token', () async {
    String? stored = jsonEncode({
      'access_token': 'embed_token',
      'refresh_token': 'refresh',
      'expires_at_ms':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      'account_id': 'acct_embed',
    });

    final client = MockClient((request) async {
      expect(request.url.host, 'api.openai.com');
      expect(request.url.path, '/v1/embeddings');
      expect(request.headers['Authorization'], 'Bearer embed_token');
      expect(request.headers['ChatGPT-Account-Id'], 'acct_embed');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'text-embedding-3-small');
      expect(body['input'], ['hello', 'world']);

      return http.Response(
        jsonEncode({
          'data': [
            {
              'index': 0,
              'embedding': [0.1, 0.2],
            },
            {
              'index': 1,
              'embedding': [0.3, 0.4],
            },
          ],
        }),
        200,
      );
    });

    final auth = CodexAuthService(
      httpClient: client,
      readStoredJson: () async => stored,
      writeStoredJson: (v) async => stored = v,
      deleteStoredJson: () async => stored = null,
    );

    final svc = CodexEmbeddingService(authService: auth, httpClient: client);
    final out = await svc.embedTexts(['hello', 'world']);
    expect(out.length, 2);
    expect(out[0][0], closeTo(0.1, 0.001));
    expect(out[1][1], closeTo(0.4, 0.001));
    expect(svc.embeddingDimensions, 1536);
  });

  test('embedTexts retries once on 401 after refresh', () async {
    String? stored = jsonEncode({
      'access_token': 'old_token',
      'refresh_token': 'refresh_xyz',
      'expires_at_ms': 0,
    });
    var embedCalls = 0;

    final client = MockClient((request) async {
      if (request.url.path.endsWith('oauth/token')) {
        return http.Response(
          jsonEncode({
            'access_token': 'new_token',
            'refresh_token': 'refresh_new',
            'expires_in': 3600,
          }),
          200,
        );
      }

      embedCalls++;
      if (embedCalls == 1) {
        return http.Response('unauthorized', 401);
      }

      expect(request.headers['Authorization'], 'Bearer new_token');
      return http.Response(
        jsonEncode({
          'data': [
            {'index': 0, 'embedding': [1.0]},
          ],
        }),
        200,
      );
    });

    final auth = CodexAuthService(
      httpClient: client,
      readStoredJson: () async => stored,
      writeStoredJson: (v) async => stored = v,
      deleteStoredJson: () async => stored = null,
    );

    final svc = CodexEmbeddingService(authService: auth, httpClient: client);
    final out = await svc.embedTexts(['x']);
    expect(embedCalls, 2);
    expect(out.single[0], 1.0);
  });

  test('embedTexts maps 429 to EmbeddingRateLimitException', () async {
    String? stored = jsonEncode({
      'access_token': 't',
      'refresh_token': 'r',
      'expires_at_ms':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });

    final client = MockClient(
      (_) async => http.Response('rate limited', 429, headers: {
        'retry-after': '30',
      }),
    );

    final auth = CodexAuthService(
      httpClient: client,
      readStoredJson: () async => stored,
    );
    final svc = CodexEmbeddingService(authService: auth, httpClient: client);

    expect(
      () => svc.embedTexts(['x']),
      throwsA(
        isA<EmbeddingRateLimitException>().having(
          (e) => e.retryAfterSeconds,
          'retry',
          30,
        ),
      ),
    );
  });

  test('embedTexts throws CodexAuthException when not signed in', () async {
    final auth = CodexAuthService(
      httpClient: MockClient((_) async => http.Response('', 500)),
      readStoredJson: () async => null,
    );
    final svc = CodexEmbeddingService(authService: auth);
    expect(
      () => svc.embedTexts(['x']),
      throwsA(isA<CodexAuthException>()),
    );
  });
}
