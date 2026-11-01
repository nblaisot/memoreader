import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memoreader/services/rag_streaming.dart';

void main() {
  test('streams OpenAI text deltas while ignoring other events', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['stream'], isTrue);
      return http.Response(
        'data: {"type":"response.created"}\n\n'
        'data: {"type":"response.output_text.delta","delta":"Hello "}\n\n'
        'data: {"type":"response.output_text.delta","delta":"world"}\n\n'
        'data: [DONE]\n\n', 200,
        headers: {'Content-Type': 'text/event-stream'},
      );
    });
    final output = await streamResponseText(
      client: client,
      endpoint: Uri.parse('https://example.test/stream'),
      headers: {},
      payload: {'stream': true},
      mistral: false,
    ).toList();
    expect(output, ['Hello ', 'world']);
  });

  test('Mistral stream exposes text and hides thinking chunks', () async {
    final client = MockClient((_) async => http.Response(
      'data: {"choices":[{"delta":{"content":['
      '{"type":"thinking","thinking":"private"},'
      '{"type":"text","text":"Answer"}]}}]}\n\n', 200));
    final output = await streamResponseText(
      client: client,
      endpoint: Uri.parse('https://example.test/stream'),
      headers: {},
      payload: {},
      mistral: true,
    ).toList();
    expect(output, ['Answer']);
  });
}
