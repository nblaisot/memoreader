import 'dart:convert';

/// Parses OpenAI Codex Responses API SSE streams into output text deltas.
class CodexSseParser {
  CodexSseParser._();

  /// Collects all `response.output_text.delta` text from an SSE body.
  static String collectOutputText(String sseBody) {
    final buffer = StringBuffer();
    for (final event in parseEvents(sseBody)) {
      if (event.type == 'response.output_text.delta') {
        final delta = event.data['delta'];
        if (delta is String && delta.isNotEmpty) {
          buffer.write(delta);
        }
      }
    }
    return buffer.toString();
  }

  static List<CodexSseEvent> parseEvents(String sseBody) {
    final events = <CodexSseEvent>[];
    String? currentEvent;
    final dataLines = <String>[];

    void flush() {
      if (dataLines.isEmpty) return;
      final raw = dataLines.join('\n').trim();
      dataLines.clear();
      if (raw.isEmpty || raw == '[DONE]') {
        currentEvent = null;
        return;
      }
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final type = (data['type'] as String?) ?? currentEvent ?? '';
        events.add(CodexSseEvent(type: type, data: data));
      } catch (_) {
        // ignore malformed chunks
      }
      currentEvent = null;
    }

    for (final line in sseBody.split('\n')) {
      if (line.startsWith('event:')) {
        flush();
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trim());
      } else if (line.trim().isEmpty) {
        flush();
      }
    }
    flush();
    return events;
  }
}

class CodexSseEvent {
  const CodexSseEvent({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;
}
