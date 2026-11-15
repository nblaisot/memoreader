import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// RAG-only configuration. Ordinary summaries retain their existing behavior.
enum RagStage { planning, retrieval, assessment, generation }

class RagGenerationRequest {
  const RagGenerationRequest({
    required this.prompt,
    required this.stage,
    this.model,
    this.schema,
  });
  final String prompt;
  final RagStage stage;
  final String? model;
  final Map<String, dynamic>? schema;
  String get effort => 'low';
  int get maxOutputTokens => switch (stage) {
    RagStage.planning => 2048,
    // Ceiling shared by reasoning and the structured assessment decision.
    // The provider can finish earlier; this does not request a 64K response.
    RagStage.assessment => 65536,
    _ => 8192,
  };
}

class RagGenerationEvent {
  const RagGenerationEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

class RagGenerationResult {
  const RagGenerationResult(
    this.text, {
    this.status = 'complete',
    this.finishReason,
    this.usage = const {},
    this.requestId,
    this.timings = const {},
  });
  final String text, status;
  final String? finishReason, requestId;
  final Map<String, dynamic> usage, timings;
  bool get complete => status == 'complete';
}

class RagGenerationException implements Exception {
  const RagGenerationException(this.kind, this.message, {this.partial = ''});
  final String kind, message, partial;
  @override
  String toString() => '$kind: $message';
}

abstract class RagGenerationService {
  Stream<RagGenerationEvent> generateRag(RagGenerationRequest request);
}

class RagWaitPolicy {
  const RagWaitPolicy({
    this.connection = const Duration(seconds: 30),
    this.headers = const Duration(seconds: 120),
    this.inactivity = const Duration(seconds: 120),
  });
  final Duration connection, headers, inactivity;
}

http.Client createRagHttpClient({
  RagWaitPolicy policy = const RagWaitPolicy(),
}) => IOClient(HttpClient()..connectionTimeout = policy.connection);

/// A session-local sink: inputs and visible results, never headers or thinking.
class RagTrace {
  RagTrace(this.sink, {this.onActivity});
  final void Function(String type, Map<String, dynamic> data) sink;
  final void Function()? onActivity;
  static const _key = #ragTrace;
  static RagTrace? get current => Zone.current[_key] as RagTrace?;
  static Future<T> run<T>(RagTrace? trace, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: trace});
  static void record(String type, Map<String, dynamic> data) =>
      current?.sink(type, data);
}

Future<RagGenerationResult> collectRag(
  RagGenerationService service,
  RagGenerationRequest request, {
  void Function(String)? onText,
}) async {
  final text = StringBuffer();
  RagGenerationResult? result;
  await for (final event in service.generateRag(request)) {
    if (event.type == 'activity') {
      RagTrace.current?.onActivity?.call();
      continue;
    }
    if (event.type == 'text') {
      final delta = event.data['text'] as String;
      text.write(delta);
      onText?.call(delta);
    } else if (event.type == 'completed') {
      result = RagGenerationResult(
        text.toString(),
        status: event.data['status'] as String,
        finishReason: event.data['finishReason'] as String?,
        usage: Map<String, dynamic>.from(event.data['usage'] as Map? ?? {}),
        requestId: event.data['requestId'] as String?,
        timings: Map<String, dynamic>.from(event.data['timings'] as Map? ?? {}),
      );
    }
  }
  return result ??
      RagGenerationResult(
        text.toString(),
        status: 'incomplete',
        finishReason: 'unexpected_eof',
      );
}

/// SSE parsing happens after byte-level activity tracking, so even heartbeat
/// comments prevent a false inactivity timeout. No thinking text is retained.
Stream<RagGenerationEvent> streamRagHttp({
  required http.Client client,
  required Uri endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> payload,
  required bool mistral,
  required RagGenerationRequest generation,
  RagWaitPolicy policy = const RagWaitPolicy(),
}) async* {
  final watch = Stopwatch()..start();
  final abort = Completer<void>();
  final callerAbort = Zone.current[#ragAbort] as Future<void>?;
  final request =
      http.AbortableRequest(
          'POST',
          endpoint,
          abortTrigger: callerAbort == null
              ? abort.future
              : Future.any([callerAbort, abort.future]),
        )
        ..headers.addAll(headers)
        ..body = jsonEncode(payload);
  final visible = StringBuffer();
  String? finish, requestId;
  var terminal = false;
  var providerFailed = false;
  final usage = <String, dynamic>{};
  final timing = <String, dynamic>{
    'dispatchUtc': DateTime.now().toUtc().toIso8601String(),
  };
  final identity = {
    'stage': generation.stage.name,
    'model': payload['model'],
    'effort': mistral
        ? payload['reasoning_effort']
        : (payload['reasoning'] as Map?)?['effort'],
    'requestedEffort': generation.effort,
    'maxOutputTokens': generation.maxOutputTokens,
    'enforcedOutputBudget':
        payload['max_tokens'] ?? payload['max_output_tokens'],
  };
  RagTrace.record('request', {...identity, 'prompt': generation.prompt});
  try {
    final response = await client
        .send(request)
        .timeout(
          policy.headers,
          onTimeout: () {
            if (!abort.isCompleted) abort.complete();
            throw const RagGenerationException(
              'headers_timeout',
              'No response headers for 120 seconds',
            );
          },
        );
    requestId =
        response.headers['x-request-id'] ?? response.headers['request-id'];
    timing['headersMs'] = watch.elapsedMilliseconds;
    RagTrace.record('headers', {
      ...identity,
      'status': response.statusCode,
      'requestId': requestId,
      ...timing,
    });
    yield RagGenerationEvent('headers', {
      'status': response.statusCode,
      'requestId': requestId,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString().timeout(
        policy.inactivity,
      );
      var unsupported = false;
      try {
        final error = (jsonDecode(body) as Map)['error'];
        if (error is Map) {
          unsupported =
              error['param'] == 'model' ||
              error['code'] == 'model_not_found' ||
              (error['message'].toString().toLowerCase().contains('model') &&
                  RegExp(
                    r'not supported|not found|does not exist|not available',
                  ).hasMatch(error['message'].toString().toLowerCase()));
        } else {
          unsupported =
              body.toLowerCase().contains('model') &&
              RegExp(
                r'not supported|not found|does not exist',
              ).hasMatch(body.toLowerCase());
        }
      } catch (_) {}
      // Only an allowlisted classification is persisted, never the body.
      throw RagGenerationException(
        unsupported ? 'unsupported_model' : 'provider_rejection',
        'HTTP ${response.statusCode}',
      );
    }
    final bytes = response.stream.timeout(
      policy.inactivity,
      onTimeout: (sink) {
        if (!abort.isCompleted) abort.complete();
        sink.addError(
          const RagGenerationException(
            'stream_inactivity',
            'No response activity for 120 seconds',
          ),
        );
        sink.close();
      },
    );
    final activity = bytes.map((b) {
      timing['firstEventMs'] ??= watch.elapsedMilliseconds;
      timing['lastActivityMs'] = watch.elapsedMilliseconds;
      RagTrace.current?.onActivity?.call();
      return b;
    });
    await for (final line
        in activity.transform(utf8.decoder).transform(const LineSplitter())) {
      yield const RagGenerationEvent('activity', {});
      if (!line.startsWith('data:')) continue;
      final value = line.substring(5).trim();
      if (value == '[DONE]') {
        terminal = true;
        continue;
      }
      if (value.isEmpty) continue;
      Map<String, dynamic> data;
      try {
        data = jsonDecode(value) as Map<String, dynamic>;
      } catch (_) {
        throw const RagGenerationException(
          'malformed_output',
          'Invalid provider event',
        );
      }
      if (data['usage'] is Map)
        usage.addAll(Map<String, dynamic>.from(data['usage'] as Map));
      if (data['model'] is String) identity['model'] = data['model'];
      var delta = '';
      if (mistral) {
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty) {
          final choice = choices.first as Map;
          if (choice['finish_reason'] != null) {
            finish = choice['finish_reason'] as String;
            terminal = true;
          }
          final content = (choice['delta'] as Map?)?['content'];
          if (content is String) delta = content;
          if (content is List) {
            delta = content
                .whereType<Map>()
                .where((c) => c['type'] == 'text')
                .map((c) => c['text'] ?? '')
                .join();
          }
        }
      } else {
        if (data['type'] == 'response.output_text.delta')
          delta = data['delta'] as String? ?? '';
        if (data['type'] == 'response.completed' ||
            data['type'] == 'response.incomplete' ||
            data['type'] == 'response.failed') {
          terminal = true;
          final response = data['response'] as Map? ?? {};
          if (response['usage'] is Map)
            usage.addAll(Map<String, dynamic>.from(response['usage'] as Map));
          finish = data['type'] == 'response.completed'
              ? 'stop'
              : (response['incomplete_details'] as Map?)?['reason']
                        as String? ??
                    'provider_failure';
          providerFailed = data['type'] == 'response.failed';
        }
        if (data['type'] == 'error')
          throw const RagGenerationException(
            'provider_rejection',
            'Provider stream error',
          );
      }
      if (delta.isNotEmpty) {
        timing['firstTextMs'] ??= watch.elapsedMilliseconds;
        visible.write(delta);
        yield RagGenerationEvent('text', {'text': delta});
      }
    }
    final complete =
        terminal && !providerFailed && finish == 'stop' && visible.isNotEmpty;
    timing['completionMs'] = watch.elapsedMilliseconds;
    final metadata = {
      ...identity,
      'status': complete ? 'complete' : 'incomplete',
      'finishReason': finish ?? 'unexpected_eof',
      'requestId': requestId,
      'usage': usage,
      'timings': timing,
    };
    RagTrace.record('response', {...metadata, 'text': visible.toString()});
    yield RagGenerationEvent('completed', metadata);
  } catch (error) {
    final kind = error is RagGenerationException
        ? error.kind
        : error is SocketException ||
              error is TimeoutException ||
              (error is http.ClientException && timing['headersMs'] == null)
        ? 'connection_failure'
        : 'transport_failure';
    RagTrace.record('request_failure', {
      ...identity,
      'kind': kind,
      'elapsedMs': watch.elapsedMilliseconds,
      'partialText': visible.toString(),
    });
    throw RagGenerationException(
      kind,
      error is RagGenerationException
          ? error.message
          : 'Request transport interrupted',
      partial: visible.toString(),
    );
  } finally {
    if (!abort.isCompleted) abort.complete();
  }
}
