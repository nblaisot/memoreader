import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_cache_service.dart';
import 'codex_auth_constants.dart';
import 'codex_auth_service.dart';
import 'codex_usage_limit_exception.dart';
import 'codex_sse_parser.dart';
import 'http_response_text.dart';
import 'resolving_http_client.dart';
import 'summary_service.dart';
import 'rag_streaming.dart';

/// Summaries via ChatGPT/Codex subscription (OAuth + Codex backend).
class CodexSummaryService implements SummaryService, RagStreamingService {
  CodexSummaryService({
    CodexAuthService? authService,
    http.Client? httpClient,
    this.model = CodexAuthConstants.defaultModel,
  }) : _auth = authService ?? CodexAuthService(httpClient: httpClient),
       _http = httpClient ?? createResolvingHttpClient();

  static const String providerId = 'openai_codex';

  final CodexAuthService _auth;
  final http.Client _http;
  final String model;
  bool usedCompatibilityFallback = false;
  final ApiCacheService _cacheService = ApiCacheService();

  @override
  String get serviceName => 'ChatGPT/Codex';

  @override
  Future<bool> isAvailable() => _auth.isConfigured();

  @override
  Future<String> generateSummary(
    String prompt,
    String language, {
    String? bookId,
    VoidCallback? onCacheHit,
  }) async {
    usedCompatibilityFallback = false;
    if (!await isAvailable()) {
      throw CodexAuthException(
        'ChatGPT/Codex is not signed in. Sign in from Settings.',
      );
    }

    final credentials = await _auth.getValidCredentials();

    final maxLength = 400000;
    final safePrompt = prompt.length > maxLength
        ? '${prompt.substring(0, maxLength)}...'
        : prompt;

    final requestPayload = {
      'model': model,
      'instructions':
          'You are a helpful assistant that follows instructions precisely and never repeats instructions in your responses.',
      'input': [
        {'role': 'user', 'content': safePrompt},
      ],
      'store': false,
      'stream': true,
      'reasoning': {'effort': 'low'},
    };

    final requestHash = _cacheService.computeRequestHash(
      providerId,
      requestPayload,
    );

    if (bookId != null) {
      final cached = await _cacheService.getCachedResponse(requestHash);
      if (cached != null) {
        onCacheHit?.call();
        return cached;
      }
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'Authorization': 'Bearer ${credentials.accessToken}',
    };
    final accountId = credentials.accountId;
    if (accountId != null && accountId.isNotEmpty) {
      headers['ChatGPT-Account-Id'] = accountId;
    }

    if (kDebugMode) {
      debugPrint(
        '[LLM] Codex request: model=$model, promptLength=${safePrompt.length}',
      );
    }

    var response = await _http.post(
      Uri.parse(CodexAuthConstants.codexResponsesUrl),
      headers: headers,
      body: jsonEncode(requestPayload),
    );

    if (response.statusCode == 401) {
      final refreshed = await _auth.refreshTokens();
      headers['Authorization'] = 'Bearer ${refreshed.accessToken}';
      response = await _http.post(
        Uri.parse(CodexAuthConstants.codexResponsesUrl),
        headers: headers,
        body: jsonEncode(requestPayload),
      );
    }

    if ((response.statusCode == 400 || response.statusCode == 404) &&
        model != CodexAuthConstants.compatibilityModel &&
        decodeHttpResponseBody(response).toLowerCase().contains('model')) {
      requestPayload['model'] = CodexAuthConstants.compatibilityModel;
      requestPayload.remove('reasoning');
      response = await _http.post(
        Uri.parse(CodexAuthConstants.codexResponsesUrl),
        headers: headers,
        body: jsonEncode(requestPayload),
      );
      usedCompatibilityFallback = response.statusCode >= 200 && response.statusCode < 300;
    }

    if (!response.statusCode.toString().startsWith('2')) {
      final body = decodeHttpResponseBody(response);
      String message = 'Codex API error (${response.statusCode})';
      int? resetsInSeconds;
      String? planType;
      String? errorType;
      try {
        final err = jsonDecode(body) as Map<String, dynamic>;
        final detail = err['error'];
        if (detail is Map && detail['message'] is String) {
          message = detail['message'] as String;
          errorType = detail['type'] as String?;
          planType = detail['plan_type'] as String?;
          final resetsRaw = detail['resets_in_seconds'];
          if (resetsRaw is int) {
            resetsInSeconds = resetsRaw;
          } else if (resetsRaw != null) {
            resetsInSeconds = int.tryParse(resetsRaw.toString());
          }
        } else if (err['detail'] is String) {
          message = err['detail'] as String;
        }
      } catch (_) {
        if (body.isNotEmpty && body.length < 500) {
          message = body;
        }
      }
      if (response.statusCode == 429 || errorType == 'usage_limit_reached') {
        throw CodexUsageLimitException(
          message,
          resetsInSeconds: resetsInSeconds,
          planType: planType,
        );
      }
      throw Exception(message);
    }

    final contentType = response.headers['content-type'] ?? '';
    final decodedBody = decodeHttpResponseBody(response);
    final summary = _collectResponseText(decodedBody, contentType);

    final trimmed = summary.trim();
    if (trimmed.isEmpty) {
      throw Exception('Codex returned an empty summary.');
    }

    if (bookId != null && !usedCompatibilityFallback) {
      await _cacheService.saveCachedResponse(
        requestHash,
        bookId,
        trimmed,
        providerId,
      );
    }

    return trimmed;
  }

  static String _collectResponseText(String body, String contentType) {
    if (contentType.contains('text/event-stream') ||
        body.trimLeft().startsWith('event:') ||
        body.contains('data:')) {
      return CodexSseParser.collectOutputText(body);
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    return _extractTextFromJsonResponse(data);
  }

  @override
  Stream<String> streamRagAnswer(String prompt, String language) async* {
    usedCompatibilityFallback = false;
    final credentials = await _auth.getValidCredentials();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${credentials.accessToken}',
      'Accept': 'text/event-stream',
      if (credentials.accountId != null)
        'ChatGPT-Account-Id': credentials.accountId!,
    };
    final payload = <String, dynamic>{
      'model': model,
      'instructions': 'Answer only from supplied excerpts and cite sources.',
      'input': [{'role': 'user', 'content': prompt}],
      'store': false,
      'stream': true,
      'reasoning': {'effort': 'low'},
    };
    Stream<String> request() => streamResponseText(
      client: _http,
      endpoint: Uri.parse(CodexAuthConstants.codexResponsesUrl),
      headers: headers,
      payload: payload,
      mistral: false,
    );
    try {
      yield* request();
    } catch (error) {
      if (error.toString().contains('401')) {
        final refreshed = await _auth.refreshTokens();
        headers['Authorization'] = 'Bearer ${refreshed.accessToken}';
        yield* request();
      } else if ((error.toString().contains('400') ||
              error.toString().contains('404')) &&
          error.toString().toLowerCase().contains('model') &&
          model != CodexAuthConstants.compatibilityModel) {
        payload['model'] = CodexAuthConstants.compatibilityModel;
        payload.remove('reasoning');
        usedCompatibilityFallback = true;
        yield* request();
      } else {
        rethrow;
      }
    }
  }

  static String _extractTextFromJsonResponse(Map<String, dynamic> data) {
    final output = data['output'];
    if (output is List) {
      final buffer = StringBuffer();
      for (final item in output) {
        if (item is! Map<String, dynamic>) continue;
        if (item['type'] == 'message') {
          final content = item['content'];
          if (content is List) {
            for (final part in content) {
              if (part is Map &&
                  part['type'] == 'output_text' &&
                  part['text'] is String) {
                buffer.write(part['text']);
              }
            }
          }
        }
      }
      return buffer.toString();
    }
    return data['output_text'] as String? ?? '';
  }
}
