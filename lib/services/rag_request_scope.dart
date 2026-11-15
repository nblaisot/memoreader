import 'dart:async';
import 'package:http/http.dart' as http;

/// A request-scoped abort signal allows reusable clients to cancel one RAG
/// operation without closing other requests sharing that client.
class RagRequestScope {
  static const _key = #ragAbort;
  static Future<void>? get abort => Zone.current[_key] as Future<void>?;
  static bool get active => abort != null;
  static Future<T> run<T>(Future<void> signal, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: signal});
}

class RagHttpClient extends http.BaseClient {
  RagHttpClient(this.inner);
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final signal = RagRequestScope.abort;
    if (signal == null ||
        request is http.AbortableRequest ||
        request is! http.Request)
      return inner.send(request);
    final cancellable =
        http.AbortableRequest(request.method, request.url, abortTrigger: signal)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection;
    return inner.send(cancellable);
  }

  @override
  void close() => inner.close();
}
