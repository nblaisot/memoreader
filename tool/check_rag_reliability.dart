// Standalone Dart integration checks: no Flutter command or device mutation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ffi';
import 'package:http/http.dart' as http;
import 'package:sqlite3/open.dart';
import 'package:memoreader/services/rag_generation.dart';
import 'package:memoreader/services/rag_history_store.dart';
import 'package:memoreader/services/rag_progress.dart';
import 'package:memoreader/models/rag_chunk.dart';

var checks = 0;
void check(bool ok, String name) {
  if (!ok) throw StateError(name);
  checks++;
  stdout.writeln('PASS $name');
}

class Client extends http.BaseClient {
  Client(this.response);
  final Future<http.StreamedResponse> Function(http.BaseRequest) response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      response(request);
}

class Provider implements RagGenerationService {
  Provider(this.client, {this.policy = const RagWaitPolicy()});
  final http.Client client;
  final RagWaitPolicy policy;
  @override
  Stream<RagGenerationEvent> generateRag(RagGenerationRequest request) =>
      streamRagHttp(
        client: client,
        endpoint: Uri.parse('https://example.test'),
        headers: {},
        payload: {'model': 'test'},
        mistral: true,
        generation: request,
        policy: policy,
      );
}

String event(String text, {String? finish}) =>
    'data: ${jsonEncode({
      'model': 'actual-model',
      'choices': [
        {
          'delta': {'content': text},
          if (finish != null) 'finish_reason': finish,
        },
      ],
    })}\n\n';
Future<void> main() async {
  final sqlite = Platform.environment['MEMOREADER_SQLITE_LIBRARY'];
  if (sqlite != null) open.overrideForAll(() => DynamicLibrary.open(sqlite));
  const request = RagGenerationRequest(
    prompt: 'Question',
    stage: RagStage.generation,
  );
  check(
    request.effort == 'low' && request.maxOutputTokens == 8192,
    'explicit effort and final budget',
  );
  check(
    const RagGenerationRequest(
              prompt: '',
              stage: RagStage.planning,
            ).maxOutputTokens ==
            2048 &&
        const RagGenerationRequest(
              prompt: '',
              stage: RagStage.assessment,
            ).maxOutputTokens ==
            65536,
    'research budgets',
  );
  final trace = <Map<String, dynamic>>[];
  final parts = StreamController<List<int>>();
  var incremental = false;
  final pending = RagTrace.run(
    RagTrace((type, data) => trace.add({'type': type, ...data})),
    () => collectRag(
      Provider(
        Client(
          (_) async => http.StreamedResponse(
            parts.stream,
            200,
            headers: {'x-request-id': 'r1'},
          ),
        ),
      ),
      request,
      onText: (_) => incremental = true,
    ),
  );
  parts.add(utf8.encode(event('Hello ')));
  await Future<void>.delayed(const Duration(milliseconds: 30));
  check(incremental, 'text delivered before stream completion');
  parts.add(utf8.encode(event('world', finish: 'stop')));
  parts.add(
    utf8.encode('data: {"usage":{"completion_tokens":5},"choices":[]}\n\n'),
  );
  await parts.close();
  final complete = await pending;
  check(
    complete.complete && complete.text == 'Hello world',
    'complete text stream',
  );
  check(
    complete.requestId == 'r1' &&
        complete.usage['completion_tokens'] == 5 &&
        complete.timings['firstTextMs'] != null,
    'usage request ID and first text timing',
  );
  check(
    trace.last['model'] == 'actual-model' &&
        trace.first['stage'] == 'generation',
    'actual model and stage persisted',
  );
  Future<RagGenerationResult> response(String body) => collectRag(
    Provider(
      Client(
        (_) async =>
            http.StreamedResponse(Stream.value(utf8.encode(body)), 200),
      ),
    ),
    request,
  );
  final limited = await response(event('Partial', finish: 'length'));
  check(
    !limited.complete &&
        limited.finishReason == 'length' &&
        limited.text == 'Partial',
    'output limit retains partial answer',
  );
  final eof = await response(event('Partial'));
  check(
    !eof.complete && eof.finishReason == 'unexpected_eof',
    'unexpected EOF is incomplete',
  );
  final done = await response(event('Partial') + 'data: [DONE]\n\n');
  check(!done.complete, 'DONE without valid finish reason is not success');
  final thinking = await response(
    'data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":"SECRET"},{"type":"text","text":"Visible"}]},"finish_reason":"stop"}]}\n\n',
  );
  check(
    thinking.text == 'Visible' && !jsonEncode(trace).contains('SECRET'),
    'thinking excluded from text and trace',
  );
  const fastPolicy = RagWaitPolicy(
    headers: Duration(milliseconds: 30),
    inactivity: Duration(milliseconds: 35),
  );
  try {
    await collectRag(
      Provider(
        Client((_) => Completer<http.StreamedResponse>().future),
        policy: fastPolicy,
      ),
      request,
    );
    throw StateError('missing failure');
  } on RagGenerationException catch (e) {
    check(e.kind == 'headers_timeout', 'header timeout classification');
  }
  final stalled = StreamController<List<int>>();
  try {
    await collectRag(
      Provider(
        Client((_) async => http.StreamedResponse(stalled.stream, 200)),
        policy: fastPolicy,
      ),
      request,
    );
    throw StateError('missing failure');
  } on RagGenerationException catch (e) {
    check(e.kind == 'stream_inactivity', 'stream inactivity classification');
  } finally {
    await stalled.close();
  }
  final heartbeats = StreamController<List<int>>();
  final alive = collectRag(
    Provider(
      Client((_) async => http.StreamedResponse(heartbeats.stream, 200)),
      policy: fastPolicy,
    ),
    request,
  );
  for (var i = 0; i < 5; i++) {
    heartbeats.add(utf8.encode(': heartbeat\n\n'));
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  heartbeats.add(utf8.encode(event('OK', finish: 'stop')));
  await heartbeats.close();
  check(
    (await alive).complete,
    'heartbeat activity exceeds idle interval without cancellation',
  );
  final abort = Completer<void>();
  final cancelClient = Client((r) async {
    final a = r as http.AbortableRequest;
    await a.abortTrigger;
    throw http.ClientException('aborted');
  });
  final cancelled = runZoned(
    () => collectRag(Provider(cancelClient), request),
    zoneValues: {#ragAbort: abort.future},
  );
  abort.complete();
  try {
    await cancelled;
    throw StateError('missing cancellation');
  } on RagGenerationException {
    check(true, 'caller abort reaches request');
  }
  check(
    ragProgressLabel(
          french: false,
          stage: RagStage.planning,
          round: 0,
          elapsed: const Duration(seconds: 3),
        ) ==
        'Searching… · 3 s',
    'initial progress no books or 0/5',
  );
  check(
    ragProgressLabel(
          french: true,
          stage: RagStage.assessment,
          round: 2,
          elapsed: const Duration(seconds: 17),
        ) ==
        'Recherche… · Étapes 2/5 · 17 s',
    'French step and elapsed seconds',
  );
  check(
    ragProgressLabel(
          french: false,
          stage: RagStage.generation,
          round: 2,
          elapsed: const Duration(seconds: 28),
        ) ==
        'Writing answer… · 28 s',
    'generation progress retains elapsed',
  );
  final dir = await Directory.systemTemp.createTemp('rag-reliability-');
  var history = RagHistoryStore(path: '${dir.path}/history.db');
  for (var i = 0; i < 6; i++) {
    await history.begin(
      'c$i',
      't$i',
      {
        'title': 'Q$i',
        'books': ['book'],
      },
      {'question': 'Q$i', 'answer': '', 'status': 'running', 'elapsedMs': 42},
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  check(
    (await history.list()).length == 5 &&
        !(await history.list()).any((c) => c['id'] == 'c0'),
    'sixth conversation prunes oldest',
  );
  await history.begin(
    'c5',
    'followup',
    {
      'title': 'Q5',
      'books': ['book'],
    },
    {'question': 'Follow-up', 'answer': '', 'status': 'running'},
  );
  check(
    (await history.turns('c5')).length == 2,
    'follow-up retains earlier turns',
  );
  final chunk = RagChunk(
    chunkId: 'p',
    bookId: 'book',
    text: 'Evidence',
    embedding: Float32List.fromList([1, 2]),
    embeddingDimension: 2,
    charStart: 0,
    charEnd: 8,
    tokenStart: 0,
    tokenEnd: 1,
    createdAt: DateTime.utc(2026),
  );
  await history.saveTurn(
    't5',
    {
      'question': 'Q5',
      'answer': 'Partial',
      'status': 'incomplete',
      'elapsedMs': 99,
    },
    [chunk],
  );
  await history.saveTurn(
    'followup',
    {'question': 'Follow-up', 'answer': 'Done', 'status': 'complete'},
    [chunk],
  );
  check(
    (await (await history.database).query('sources')).length == 1,
    'source snapshots deduplicated',
  );
  final restored = await history.turns('c5');
  check(
    RagHistoryStore.decodeSources(restored.first).first.text == 'Evidence',
    'sources hydrate independently of index',
  );
  await history.event('c5', 't5', 'a1', 'request', {
    'prompt': 'Question',
    'authorization': 'SECRET',
    'nested': {'access_token': 'SECRET', 'thinking': 'SECRET', 'model': 'safe'},
  });
  final exported = jsonEncode(await history.export(conversationId: 'c5'));
  check(
    !exported.contains('SECRET') && !exported.contains('"embedding":'),
    'credentials thinking and vectors excluded',
  );
  check(
    exported.contains('Partial') && exported.contains('Follow-up'),
    'export retains complete conversation',
  );
  await history.close();
  history = RagHistoryStore(path: '${dir.path}/history.db');
  check(
    (await history.turns('c4')).single['status'] == 'interrupted',
    'restart recovers running attempt as interrupted',
  );
  await history.delete('c5');
  check(
    (await (await history.database).query('sources')).isEmpty &&
        (await (await history.database).query('events')).isEmpty,
    'delete cascades sources and diagnostics',
  );
  await history.close();
  await dir.delete(recursive: true);
  stdout.writeln('$checks checks passed');
}
