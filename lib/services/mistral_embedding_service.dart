import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'rag_embedding_service.dart';
export 'rag_embedding_service.dart' show EmbeddingRateLimitException;

/// Service for generating embeddings using Mistral AI API
class MistralEmbeddingService implements EmbeddingService {
  final String apiKey;
  final String model; // 'mistral-embed'

  static const String _apiUrl = 'https://api.mistral.ai/v1/embeddings';
  static const String _defaultModel = 'mistral-embed';
  static const int _defaultDimensions = 1024;

  MistralEmbeddingService(this.apiKey, {String? model})
      : model = model ?? _defaultModel;

  @override
  String get providerName => 'Mistral AI';

  @override
  String get modelName => model;

  @override
  int get embeddingDimensions => _defaultDimensions;

  @override
  int get maxTokensPerInput {
    // Mistral's `mistral-embed` model supports long contexts; use a conservative
    // per-input limit to stay compatible with typical deployments. Adjust if
    // you adopt a different model or updated limits.
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
      throw Exception('Mistral API key is not configured');
    }

    if (texts.isEmpty) {
      return [];
    }

    try {
      // Batch embedding request (check API limits - typically 50-512 inputs)
      // For safety, we'll batch into smaller groups
      const batchSize = 100; // Conservative batch size
      final allEmbeddings = <Float32List>[];

      for (int i = 0; i < texts.length; i += batchSize) {
        final batch = texts.sublist(
          i,
          i + batchSize > texts.length ? texts.length : i + batchSize,
        );

        final requestPayload = {
          'model': model,
          'input': batch,
        };

        if (kDebugMode) {
          debugPrint('[RAG] Mistral embedding request: model=$model, batchSize=${batch.length}');
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

          allEmbeddings.addAll(embeddings);

          if (kDebugMode) {
            debugPrint('[RAG] Mistral embedding response: received ${embeddings.length} embeddings');
          }
        } else if (response.statusCode == 429) {
          // Rate limit error - extract Retry-After header if available
          final retryAfterHeader = response.headers['retry-after'];
          final retryAfter = retryAfterHeader != null ? int.tryParse(retryAfterHeader) : null;
          
          throw EmbeddingRateLimitException(
            'Mistral rate limit exceeded. ${retryAfter != null ? "Retry after $retryAfter seconds." : "Please try again later."}',
            retryAfterSeconds: retryAfter ?? 60, // Default to 60s if not specified
          );
        } else {
          final errorData = jsonDecode(response.body);
          throw Exception(
            'Mistral API error: ${errorData['error']?['message'] ?? response.statusCode}',
          );
        }
        
        // Note: Removed artificial delay - rate limiting is handled by retry logic
      }

      return allEmbeddings;
    } catch (e) {
      if (e is EmbeddingRateLimitException) {
        rethrow;
      }
      debugPrint('Error generating embeddings with Mistral: $e');
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
