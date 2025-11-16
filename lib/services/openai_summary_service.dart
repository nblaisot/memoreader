import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'summary_service.dart';

/// Service for generating summaries using OpenAI API
/// 
/// This service requires an API key to be configured by the user.
class OpenAISummaryService implements SummaryService {
  final String apiKey;
  
  static const String _apiUrl = 'https://api.openai.com/v1/chat/completions';
  
  OpenAISummaryService(this.apiKey);

  @override
  String get serviceName => 'OpenAI (GPT)';

  @override
  Future<bool> isAvailable() async {
    return apiKey.isNotEmpty;
  }

  @override
  Future<String> generateSummary(String prompt, String language) async {
    if (!await isAvailable()) {
      throw Exception('OpenAI API key is not configured');
    }

    try {
      // Use the prompt as-is - it already contains anti-leakage instructions
      // from EnhancedSummaryService. Only truncate if necessary for token limits.
      // GPT-3.5-turbo has 4096 token context, leave room for response
      final maxLength = 12000; // Conservative limit to leave room for response
      final safePrompt = prompt.length > maxLength
          ? '${prompt.substring(0, maxLength)}...'
          : prompt;

      if (kDebugMode) {
        debugPrint('[LLM] OpenAI request: model=gpt-3.5-turbo, promptLength=${safePrompt.length}');
        debugPrint('[LLM] OpenAI prompt begin >>>');
        debugPrint(safePrompt);
        debugPrint('[LLM] OpenAI prompt end <<<');
      }

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'gpt-3.5-turbo',
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
          'max_tokens': 1000, // Increased to allow for longer summaries
          'temperature': 0.7,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final summary = data['choices'][0]['message']['content'] as String;
        if (kDebugMode) {
          debugPrint('[LLM] OpenAI response ok: summaryLength=${summary.length}');
        }
        return summary.trim();
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception('OpenAI API error: ${errorData['error']['message'] ?? response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error generating summary with OpenAI: $e');
      rethrow;
    }
  }
}



