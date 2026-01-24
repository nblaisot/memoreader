import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'rag_embedding_service.dart';
export 'rag_embedding_service.dart' show EmbeddingRateLimitException;

/// Service for generating embeddings using OpenAI API
class OpenAIEmbeddingService implements EmbeddingService {
  final String apiKey;
  final String model; // 'text-embedding-3-small' or 'text-embedding-3-large'

  static const String _apiUrl = 'https://api.openai.com/v1/embeddings';
  static const String _defaultModel = 'text-embedding-3-small';
  static const int _defaultDimensions = 1536;
  
  // Model dimensions mapping
  static const Map<String, int> _modelDimensions = {
    'text-embedding-3-small': 1536,
    'text-embedding-3-large': 3072,
  };

  OpenAIEmbeddingService(this.apiKey, {String? model})
      : model = model ?? _defaultModel;

  @override
  String get providerName => 'OpenAI';

  @override
  String get modelName => model;

  @override
  int get embeddingDimensions => _modelDimensions[model] ?? _defaultDimensions;

  @override
  int get maxTokensPerInput {
    // According to OpenAI documentation, text-embedding-3 models currently
    // support up to 8192 tokens per input. Adjust if you change models.
    return 8192;
  }

  @override
  Future<bool> isAvailable() async {
    return apiKey.isNotEmpty;
  }

  @override
  Future<Float32List> embedText(String text) async {
    final results = await embedTexts([text]);
    return results.first;
  }

  @override
  Future<List<Float32List>> embedTexts(List<String> texts) async {
    if (!await isAvailable()) {
      throw Exception('OpenAI API key is not configured');
    }

    if (texts.isEmpty) {
      return [];
    }

    try {
      // Batch embedding request (up to 2048 inputs per request)
      final requestPayload = {
        'model': model,
        'input': texts,
      };

      if (kDebugMode) {
        debugPrint('[RAG] OpenAI embedding request: model=$model, batchSize=${texts.length}');
      }

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(requestPayload),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final embeddings = (data['data'] as List)
            .map((item) => _parseEmbedding(item['embedding'] as List))
            .toList();

        if (kDebugMode) {
          debugPrint('[RAG] OpenAI embedding response: received ${embeddings.length} embeddings');
        }

        return embeddings;
      } else if (response.statusCode == 429) {
        // Rate limit error - extract Retry-After header if available
        final retryAfterHeader = response.headers['retry-after'] ?? 
                                  response.headers['x-ratelimit-reset-requests'];
        final retryAfter = retryAfterHeader != null ? int.tryParse(retryAfterHeader) : null;
        
        throw EmbeddingRateLimitException(
          'OpenAI rate limit exceeded. ${retryAfter != null ? "Retry after $retryAfter seconds." : "Please try again later."}',
          retryAfterSeconds: retryAfter ?? 60, // Default to 60s if not specified
        );
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception(
          'OpenAI API error: ${errorData['error']?['message'] ?? response.statusCode}',
        );
      }
    } catch (e) {
      if (e is EmbeddingRateLimitException) {
        rethrow;
      }
      debugPrint('Error generating embeddings with OpenAI: $e');
      rethrow;
    }
  }

  /// Parse embedding list to Float32List
  Float32List _parseEmbedding(List<dynamic> embedding) {
    return Float32List.fromList(
      embedding.map((e) => (e as num).toDouble()).toList(),
    );
  }
}
