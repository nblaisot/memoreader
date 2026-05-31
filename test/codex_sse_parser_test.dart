import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/codex_sse_parser.dart';

void main() {
  test('collectOutputText joins output_text deltas', () {
    const sse = '''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Hello "}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"world"}

''';
    expect(CodexSseParser.collectOutputText(sse), 'Hello world');
  });

  test('ignores non-text events', () {
    const sse = '''
event: response.completed
data: {"type":"response.completed"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"ok"}

''';
    expect(CodexSseParser.collectOutputText(sse), 'ok');
  });
}
