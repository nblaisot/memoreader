import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'summary_service.dart';

/// Service for generating summaries using Mistral AI API
/// 
/// This service requires an API key to be configured by the user.
/// Mistral AI provides high-quality models with competitive pricing.
class MistralSummaryService implements SummaryService {
  final String apiKey;
  
  static const String _apiUrl = 'https://api.mistral.ai/v1/chat/completions';
  
  MistralSummaryService(this.apiKey);

  @override
  String get serviceName => 'Mistral AI';

  @override
  Future<bool> isAvailable() async {
    return apiKey.isNotEmpty;
  }

  @override
  Future<String> generateSummary(String prompt, String language) async {
    if (!await isAvailable()) {
      throw Exception('Mistral API key is not configured');
    }

    try {
      // Use the prompt as-is - it already contains anti-leakage instructions
      // from EnhancedSummaryService. Only truncate if necessary for token limits.
      // Mistral-small has 32K token context (128K characters with ~4 chars/token)
      // Reserve ~3K tokens for response, use ~29K tokens for input
      // 29K tokens × 4 chars/token = ~116K characters
      // Use conservative 110K to account for prompt overhead (system message, etc.)
      final maxLength = 110000; // Allow full use of 32K token context
      final safePrompt = prompt.length > maxLength
          ? '${prompt.substring(0, maxLength)}...'
          : prompt;

      if (kDebugMode) {
        debugPrint('[LLM] Mistral request: model=mistral-small-latest, promptLength=${safePrompt.length}');
        debugPrint('[LLM] Mistral prompt begin >>>');
        debugPrint(safePrompt);
        debugPrint('[LLM] Mistral prompt end <<<');
      }

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'mistral-small-latest', // Good balance of quality and cost
          'messages': [
            {
              'role': 'system',
              'content': 'You are a helpful assistant that follows instructions precisely and never repeats instructions in your responses.',
            },
            {
              'role': 'user',
              'content': safePrompt,
            },
          ],
          'max_tokens': 2000, // Increased to allow for longer summaries with larger context
          'temperature': 0.7,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final summary = data['choices'][0]['message']['content'] as String;
        if (kDebugMode) {
          debugPrint('[LLM] Mistral response ok: summaryLength=${summary.length}');
        }
        return summary.trim();
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception('Mistral API error: ${errorData['error']?['message'] ?? response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error generating summary with Mistral: $e');
      rethrow;
    }
  }
}

