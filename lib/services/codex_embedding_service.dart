import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'codex_auth_constants.dart';
import 'codex_auth_service.dart';
import 'http_response_text.dart';
import 'resolving_http_client.dart';
import 'rag_embedding_service.dart';
export 'rag_embedding_service.dart' show EmbeddingRateLimitException;

/// Embeddings via ChatGPT/Codex OAuth against OpenAI's embeddings API.
class CodexEmbeddingService implements EmbeddingService {
  CodexEmbeddingService({
    CodexAuthService? authService,
    http.Client? httpClient,
    String? model,
  }) : _auth = authService ?? CodexAuthService(httpClient: httpClient),
       _http = httpClient ?? createResolvingHttpClient(),
       model = model ?? CodexAuthConstants.defaultEmbeddingModel;

  static const String _providerLabel = 'ChatGPT/Codex';

  static const Map<String, int> _modelDimensions = {
    'text-embedding-3-small': 1536,
    'text-embedding-3-large': 3072,
  };

  final CodexAuthService _auth;
  final http.Client _http;
  final String model;

  @override
  String get providerName => _providerLabel;

  @override
  String get modelName => model;

  @override
  int get embeddingDimensions =>
      _modelDimensions[model] ?? _modelDimensions['text-embedding-3-small']!;

  @override
  int get maxTokensPerInput => 8192;

  @override
  Future<bool> isAvailable() => _auth.isConfigured();

  @override
  Future<Float32List> embedText(String text) async {
    final results = await embedTexts([text]);
    return results.first;
  }

  @override
  Future<List<Float32List>> embedTexts(List<String> texts) async {
    if (!await isAvailable()) {
      throw CodexAuthException(
        'ChatGPT/Codex is not signed in. Sign in from Settings.',
      );
    }

    if (texts.isEmpty) {
      return [];
    }

    var credentials = await _auth.getValidCredentials();
    var response = await _postEmbeddings(credentials, texts);

    if (response.statusCode == 401) {
      credentials = await _auth.refreshTokens();
      response = await _postEmbeddings(credentials, texts);
    }

    return _parseResponse(response);
  }

  Future<http.Response> _postEmbeddings(
    CodexAuthCredentials credentials,
    List<String> texts,
  ) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${credentials.accessToken}',
    };
    final accountId = credentials.accountId;
    if (accountId != null && accountId.isNotEmpty) {
      headers['ChatGPT-Account-Id'] = accountId;
    }

    if (kDebugMode) {
      debugPrint(
        '[RAG] Codex embedding request: model=$model, batchSize=${texts.length}',
      );
    }

    return _http.post(
      Uri.parse(CodexAuthConstants.codexEmbeddingsUrl),
      headers: headers,
      body: jsonEncode({'model': model, 'input': texts}),
    );
  }

  List<Float32List> _parseResponse(http.Response response) {
    if (response.statusCode == 200) {
      final data =
          jsonDecode(decodeHttpResponseBody(response)) as Map<String, dynamic>;
      final items = data['data'] as List<dynamic>;
      final sorted = List<Map<String, dynamic>>.from(
        items.map((e) => e as Map<String, dynamic>),
      )..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));

      final embeddings = sorted
          .map((item) => _parseEmbedding(item['embedding'] as List<dynamic>))
          .toList();

      if (kDebugMode) {
        debugPrint(
          '[RAG] Codex embedding response: received ${embeddings.length} embeddings',
        );
      }
      return embeddings;
    }

    if (response.statusCode == 429) {
      final retryAfterHeader =
          response.headers['retry-after'] ??
          response.headers['x-ratelimit-reset-requests'];
      final retryAfter = retryAfterHeader != null
          ? int.tryParse(retryAfterHeader)
          : null;
      throw EmbeddingRateLimitException(
        'ChatGPT/Codex rate limit exceeded. '
        '${retryAfter != null ? "Retry after $retryAfter seconds." : "Please try again later."}',
        retryAfterSeconds: retryAfter ?? 60,
      );
    }

    final body = decodeHttpResponseBody(response);
    String message = 'ChatGPT/Codex embedding error (${response.statusCode})';
    try {
      final errorData = jsonDecode(body) as Map<String, dynamic>;
      final err = errorData['error'];
      if (err is Map && err['message'] is String) {
        message = err['message'] as String;
      }
    } catch (_) {
      if (body.isNotEmpty && body.length < 500) {
        message = body;
      }
    }
    throw Exception(message);
  }

  Float32List _parseEmbedding(List<dynamic> embedding) {
    return Float32List.fromList(
      embedding.map((e) => (e as num).toDouble()).toList(),
    );
  }
}
