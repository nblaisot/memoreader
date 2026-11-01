import 'dart:convert';
import 'package:http/http.dart' as http;

/// Optional live text stream for answers. Planning still uses the small
/// request/response API because its JSON result is consumed as one decision.
abstract class RagStreamingService {
  Stream<String> streamRagAnswer(String prompt, String language);
}

Stream<String> streamResponseText({
  required http.Client client,
  required Uri endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> payload,
  required bool mistral,
}) async* {
  final request = http.Request('POST', endpoint)
    ..headers.addAll(headers)
    ..body = jsonEncode(payload);
  final response = await client.send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final body = await response.stream.bytesToString();
    throw Exception('Generation request failed (${response.statusCode}): $body');
  }
  await for (final line in response.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') continue;
    Map<String, dynamic> event;
    try {
      event = jsonDecode(data) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    if (event['type'] == 'error' || event['type'] == 'response.failed') {
      throw Exception('Generation stream failed: $data');
    }
    if (mistral) {
      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final delta = choices.first is Map ? (choices.first as Map)['delta'] : null;
      if (delta is! Map) continue;
      final content = delta['content'];
      if (content is String && content.isNotEmpty) yield content;
      if (content is List) {
        for (final item in content.whereType<Map>()) {
          if (item['type'] == 'text' && item['text'] is String) {
            yield item['text'] as String;
          }
        }
      }
    } else if (event['type'] == 'response.output_text.delta' &&
        event['delta'] is String) {
      yield event['delta'] as String;
    }
  }
}
