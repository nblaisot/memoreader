import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memoreader/services/api_cache_service.dart';
import 'package:memoreader/services/mistral_summary_service.dart';
import 'package:memoreader/services/openai_summary_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiCacheService().clearAllCache();
  });

  group('OpenAISummaryService', () {
    test('isAvailable is false when key is empty', () async {
      final svc = OpenAISummaryService('');
      expect(await svc.isAvailable(), isFalse);
    });

    test('generateSummary throws when key missing', () async {
      final svc = OpenAISummaryService('', httpClient: MockClient((_) async {
        throw AssertionError('no HTTP');
      }));
      expect(
        () => svc.generateSummary('p', 'en'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('API key'),
        )),
      );
    });

    test('POSTs chat completions and returns trimmed content', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.host, 'api.openai.com');
        expect(request.headers['Authorization'], 'Bearer sk-test');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'gpt-4o');
        final messages = body['messages'] as List<dynamic>;
        expect(messages.length, 2);
        expect((messages[1] as Map)['content'], 'user prompt');

        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '  AI summary  '},
              },
            ],
          }),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final svc = OpenAISummaryService('sk-test', httpClient: client);
      final out = await svc.generateSummary('user prompt', 'en');
      expect(out, 'AI summary');
    });

    test('maps API errors to Exception', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'message': 'model not found'},
          }),
          400,
        ),
      );
      final svc = OpenAISummaryService('sk-test', httpClient: client);
      expect(
        () => svc.generateSummary('p', 'en'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('model not found'),
        )),
      );
    });
  });

  group('MistralSummaryService', () {
    test('POSTs chat completions and returns trimmed content', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'api.mistral.ai');
        expect(request.headers['Authorization'], 'Bearer mk');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'mistral-large-latest');

        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'mistral out'},
              },
            ],
          }),
          200,
        );
      });

      final svc = MistralSummaryService('mk', httpClient: client);
      final out = await svc.generateSummary('hello', 'fr');
      expect(out, 'mistral out');
    });

    test('maps API errors to Exception', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'message': 'invalid key'},
          }),
          401,
        ),
      );
      final svc = MistralSummaryService('mk', httpClient: client);
      expect(
        () => svc.generateSummary('p', 'en'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('invalid key'),
        )),
      );
    });
  });
}
