import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:memoreader/services/rag_request_scope.dart';

class PendingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request, isA<http.Abortable>());
    await (request as http.Abortable).abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  test('scope cancellation reaches an active HTTP request', () async {
    final abort = Completer<void>();
    final client = RagHttpClient(PendingClient());
    final response = RagRequestScope.run(
      abort.future,
      () =>
          client.post(Uri.parse('https://example.test'), body: 'book evidence'),
    );
    abort.complete();
    await expectLater(response, throwsA(isA<http.RequestAbortedException>()));
  });
  test('scopes do not leak cancellation across concurrent requests', () async {
    final abort = Completer<void>();
    expect(RagRequestScope.active, false);
    await RagRequestScope.run(abort.future, () async {
      expect(RagRequestScope.active, true);
    });
    expect(RagRequestScope.active, false);
  });
}
