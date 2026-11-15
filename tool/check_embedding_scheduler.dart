// Deterministic HTTP fixtures and real SQLite/isolate coordination; no API keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi';
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:memoreader/services/embedding_scheduler.dart';
import 'package:memoreader/services/embedding_throttle_store.dart';
import 'package:memoreader/services/openai_embedding_service.dart';
import 'package:memoreader/services/mistral_embedding_service.dart';
import 'package:memoreader/services/rag_generation.dart';
import 'package:memoreader/services/rag_request_scope.dart';
import 'package:memoreader/models/rag_index_progress.dart';

int checks = 0;
void check(bool value, String name) {
  if (!value) throw StateError(name);
  checks++;
  print('PASS $name');
}

class Clock {
  DateTime time = DateTime.utc(2026, 11, 15);
  final sleeps = <Duration>[];
  DateTime now() => time;
  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    time = time.add(d);
  }
}

class Client extends http.BaseClient {
  Client(this.response);
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    int n,
  )
  response;
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response(request, ++calls);
}

http.StreamedResponse reply(
  int status,
  Object body, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body is String ? body : jsonEncode(body))),
  status,
  headers: headers,
);
Map<String, dynamic> vectors(
  int count, {
  int dims = 1536,
  bool reverse = false,
}) => {
  'data': [
    for (var j = 0; j < count; j++)
      {
        'index': reverse ? count - j - 1 : j,
        'embedding': List.filled(
          dims,
          (reverse ? count - j : j + 1).toDouble(),
        ),
      },
  ],
  'usage': {'prompt_tokens': 40, 'total_tokens': 40},
};
void sqliteLibrary() {
  final library = Platform.environment['MEMOREADER_SQLITE_LIBRARY'];
  if (library != null) open.overrideForAll(() => DynamicLibrary.open(library));
}

Future<Database> connect(String path) async {
  sqliteLibrary();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute('PRAGMA busy_timeout = 10000');
  await SqliteEmbeddingThrottleStore.create(db);
  return db;
}

void contender((String, SendPort, SendPort) args) async {
  try {
    final db = await connect(args.$1);
    final commands = ReceivePort();
    args.$2.send(commands.sendPort);
    await for (final message in commands) {
      if (message == 'claim') {
        final permit = await EmbeddingScheduler(
          SqliteEmbeddingThrottleStore(db),
          'shared',
        ).claim('worker-${Isolate.current.hashCode}', 100, false);
        args.$3.send(permit.granted);
        break;
      }
    }
    commands.close();
    await db.close();
  } catch (e) {
    args.$3.send(e.toString());
  }
}

Future<void> main() async {
  final clock = Clock();
  check(
    parseEmbeddingDelay('0.25', clock.now()) ==
        const Duration(milliseconds: 250),
    'fractional Retry-After',
  );
  check(
    parseEmbeddingDelay('6m0.5s', clock.now()) ==
        const Duration(milliseconds: 360500),
    'compound duration reset',
  );
  check(
    parseEmbeddingDelay('150ms', clock.now()) ==
        const Duration(milliseconds: 150),
    'millisecond reset',
  );
  check(
    parseEmbeddingDelay(
          HttpDate.format(clock.now().add(const Duration(seconds: 45))),
          clock.now(),
        ) ==
        const Duration(seconds: 45),
    'HTTP date Retry-After',
  );
  check(
    parseEmbeddingDelay('nonsense', clock.now()) == null &&
        parseEmbeddingDelay('-5', clock.now()) == null,
    'invalid delays rejected',
  );
  final limits = EmbeddingLimitHeaders({
    'Retry-After': '1',
    'x-ratelimit-remaining-tokens': '0',
    'x-ratelimit-reset-tokens': '30s',
  }, clock.now());
  check(
    limits.retryAfter == const Duration(seconds: 30),
    'most restrictive applicable limit respected',
  );
  final memory = MemoryEmbeddingThrottleStore();
  final scheduler = EmbeddingScheduler(
    memory,
    'bucket',
    now: clock.now,
    sleep: clock.sleep,
    random: () => 0,
  );
  check(
    (await scheduler.claim('a', 100, false)).granted,
    'first request granted',
  );
  check(
    !(await scheduler.claim('b', 100, false)).granted,
    'concurrent request blocked by shared lease',
  );
  await scheduler.finish('b', success: true);
  check(
    !(await scheduler.claim('c', 100, false)).granted,
    'non-owner cannot release permit',
  );
  await scheduler.finish(
    'a',
    limits: EmbeddingLimitHeaders({'retry-after': '1'}, clock.now()),
    throttled: true,
  );
  final next1 = await scheduler.nextEligible();
  check(
    next1.difference(clock.now()) >= const Duration(seconds: 2),
    'short provider hint cannot defeat backoff',
  );
  clock.time = next1;
  await scheduler.claim('b', 100, false);
  await scheduler.finish(
    'b',
    limits: EmbeddingLimitHeaders({'retry-after': '1'}, clock.now()),
    throttled: true,
  );
  final next2 = await scheduler.nextEligible();
  check(
    next2.difference(clock.now()) >= const Duration(seconds: 4),
    'repeated throttling increases backoff',
  );
  clock.time = next2;
  await scheduler.claim('b', 100, false);
  await scheduler.finish(
    'b',
    success: true,
    limits: EmbeddingLimitHeaders({
      'x-ratelimit-remaining-tokens': '10',
      'x-ratelimit-reset-tokens': '20s',
    }, clock.now()),
  );
  check(
    !(await scheduler.claim('background', 100, false)).granted,
    'insufficient token budget pauses large batch',
  );
  check(
    (await scheduler.claim('interactive', 2, true)).granted,
    'small interactive request can use available token budget',
  );
  await scheduler.finish('interactive', success: true);
  await scheduler.claim('current', 1, false);
  check(
    !(await scheduler.claim('priority', 1, true)).granted,
    'interactive waits for active transport',
  );
  await scheduler.finish('current', success: true);
  check(
    !(await scheduler.claim('queued-background', 1, false)).granted,
    'interactive waiter has priority over new background work',
  );
  check(
    (await scheduler.claim('priority', 1, true)).granted,
    'priority request granted after active transport finishes',
  );
  await scheduler.finish('priority', success: true);

  final project = EmbeddingLimitHeaders({
    'retry-after': '1',
    'x-ratelimit-remaining-project-tokens': '0',
    'x-ratelimit-reset-project-tokens': '2m',
  }, clock.now());
  check(
    project.retryAfter == const Duration(minutes: 2),
    'project token cooldown is not bypassed',
  );
  final abandonedClock = Clock();
  final abandoned = EmbeddingScheduler(
    MemoryEmbeddingThrottleStore(),
    'lease-recovery',
    now: abandonedClock.now,
  );
  await abandoned.claim('dead-worker', 1, false);
  abandonedClock.time = abandonedClock.time.add(const Duration(seconds: 181));
  check(
    (await abandoned.claim('restarted-worker', 1, false)).granted,
    'expired request lease recovers after process interruption',
  );
  await abandoned.finish('dead-worker', success: true);
  check(
    !(await abandoned.claim('third-worker', 1, false)).granted,
    'late completion cannot release a newer request lease',
  );
  final independent = EmbeddingScheduler(
    memory,
    'other-profile',
    now: clock.now,
  );
  check(
    (await independent.claim('independent', 1000, false)).granted,
    'another credential profile is not blocked by this cooldown',
  );

  final httpClock = Clock();
  final store = MemoryEmbeddingThrottleStore();
  final client = Client(
    (request, n) => n < 3
        ? reply(
            429,
            {
              'error': {'code': 'rate_limit_exceeded'},
            },
            headers: {'retry-after': '1'},
          )
        : reply(200, vectors(2, reverse: true)),
  );
  final service = OpenAIEmbeddingService(
    'fixture-key',
    client: client,
    throttleStore: () async => store,
    now: httpClock.now,
    sleep: httpClock.sleep,
    random: () => 0,
  );
  final trace = <String>[];
  final actual = await RagTrace.run(
    RagTrace((type, data) => trace.add(jsonEncode({'type': type, ...data}))),
    () => service.embedTexts(['one', 'two']),
  );
  check(
    client.calls == 3 &&
        actual.length == 2 &&
        actual[0].first == 1 &&
        actual[1].first == 2,
    'HTTP throttling recovers and restores response ordering',
  );
  check(
    httpClock.sleeps[0] >= const Duration(seconds: 2) &&
        httpClock.sleeps[1] >= const Duration(seconds: 4),
    'HTTP retries use increasing delays',
  );
  check(
    !trace.join().contains('fixture-key') &&
        !trace.join().contains('embedding":[') &&
        !trace.join().contains('one'),
    'diagnostics exclude credentials vectors and source inputs',
  );
  final quota = Client(
    (_, __) => reply(429, {
      'error': {'code': 'insufficient_quota', 'message': 'secret unsafe body'},
    }),
  );
  var kind = '';
  try {
    await OpenAIEmbeddingService(
      'quota-key',
      client: quota,
      throttleStore: () async => MemoryEmbeddingThrottleStore(),
    ).embedText('text');
  } on EmbeddingProviderException catch (e) {
    kind = e.kind;
    check(!e.toString().contains('secret'), 'raw error response redacted');
  }
  check(
    kind == 'quota' && quota.calls == 1,
    'quota is terminal and never retried',
  );
  for (final status in [400, 401, 403, 404]) {
    final c = Client(
      (_, __) => reply(status, {
        'error': {'code': 'rejected'},
      }),
    );
    try {
      await OpenAIEmbeddingService(
        'reject-$status',
        client: c,
      ).embedText('text');
    } on EmbeddingProviderException catch (_) {}
    check(c.calls == 1, 'HTTP $status is actionable and not retried');
  }
  final longClock = Clock();
  final longClient = Client(
    (_, __) => reply(
      429,
      {
        'error': {'code': 'rate_limit_exceeded'},
      },
      headers: {'retry-after': '1200'},
    ),
  );
  DateTime? until;
  final persistent = MemoryEmbeddingThrottleStore();
  final longService = OpenAIEmbeddingService(
    'long-key',
    client: longClient,
    throttleStore: () async => persistent,
    now: longClock.now,
    sleep: longClock.sleep,
    random: () => 0,
  );
  try {
    await longService.embedText('text');
  } on EmbeddingDeferredException catch (e) {
    until = e.nextEligibleAt;
  }
  check(
    longClient.calls == 1 &&
        until!.difference(longClock.now()) >= const Duration(minutes: 20),
    'long provider cooldown deferred without early retry',
  );
  try {
    await longService.embedText('text');
  } on EmbeddingDeferredException {}
  check(
    longClient.calls == 1,
    'another job respects the persisted shared cooldown',
  );
  final failClock = Clock();
  final fail = Client(
    (_, __) => reply(429, {
      'error': {'code': 'rate_limit_exceeded'},
    }),
  );
  var deferred = false;
  try {
    await OpenAIEmbeddingService(
      'bounded-key',
      client: fail,
      now: failClock.now,
      sleep: failClock.sleep,
      random: () => 0,
    ).embedText('text');
  } on EmbeddingDeferredException {
    deferred = true;
  }
  check(
    deferred && fail.calls == 8,
    'attempt budget defers after exactly eight requests',
  );
  final deadlineClock = Clock();
  final slow = Client((_, __) {
    deadlineClock.time = deadlineClock.time.add(const Duration(minutes: 2));
    return reply(429, {
      'error': {'code': 'rate_limit_exceeded'},
    });
  });
  deferred = false;
  try {
    await OpenAIEmbeddingService(
      'deadline-key',
      client: slow,
      now: deadlineClock.now,
      sleep: deadlineClock.sleep,
      random: () => 0,
    ).embedText('text');
  } on EmbeddingDeferredException {
    deferred = true;
  }
  check(
    deferred && slow.calls <= 5,
    'elapsed retry budget prevents further dispatch',
  );
  final batchedMistral = Client((request, _) {
    final inputs = jsonDecode((request as http.Request).body)['input'] as List;
    return reply(200, vectors(inputs.length, dims: 1024));
  });
  final mistralVectors = await MistralEmbeddingService(
    'mistral-batch-fixture',
    client: batchedMistral,
  ).embedTexts(List.filled(101, 'text'));
  check(
    batchedMistral.calls == 2 && mistralVectors.length == 101,
    'Mistral input batching preserved',
  );

  final bad = Client((_, __) => reply(200, vectors(1, dims: 2)));
  kind = '';
  try {
    await OpenAIEmbeddingService('bad-key', client: bad).embedText('text');
  } on EmbeddingProviderException catch (e) {
    kind = e.kind;
  }
  check(
    kind == 'invalid_response' && bad.calls == 1,
    'bad vector dimensions cannot reach checkpoint',
  );
  final overloadClock = Clock();
  final overload = Client(
    (_, n) => n == 1 ? reply(503, '<html>Busy</html>') : reply(200, vectors(1)),
  );
  await OpenAIEmbeddingService(
    'overload',
    client: overload,
    now: overloadClock.now,
    sleep: overloadClock.sleep,
    random: () => 0,
  ).embedText('text');
  check(
    overload.calls == 2,
    'temporary non-JSON overload response is retryable',
  );
  final mistral = Client((request, _) {
    check(request.url.host == 'api.mistral.ai', 'Mistral endpoint preserved');
    return reply(200, vectors(1, dims: 1024));
  });
  check(
    (await MistralEmbeddingService(
          'mistral-fixture',
          client: mistral,
        ).embedText('text')).length ==
        1024,
    'Mistral model dimensions preserved with shared scheduling',
  );

  final abort = Completer<void>();
  final blockStore = MemoryEmbeddingThrottleStore();
  final blockScheduler = EmbeddingScheduler(blockStore, 'blocked');
  await blockScheduler.claim('first', 1, false);
  final waiting = blockScheduler.acquire(
    'cancelled',
    1,
    false,
    DateTime.now().add(const Duration(seconds: 3)),
    abort: abort.future,
  );
  abort.complete();
  kind = '';
  try {
    await waiting;
  } on EmbeddingProviderException catch (e) {
    kind = e.kind;
  }
  check(kind == 'cancelled', 'cancellation interrupts queued waiting');
  final transportAbort = Completer<void>();
  final transport = Client((r, _) async {
    await (r as http.AbortableRequest).abortTrigger;
    throw http.RequestAbortedException();
  });
  final transportFuture = RagRequestScope.run(
    transportAbort.future,
    () => OpenAIEmbeddingService(
      'transport-abort',
      client: transport,
    ).embedText('text'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
  transportAbort.complete();
  var cancelled = false;
  try {
    await transportFuture;
  } on http.RequestAbortedException {
    cancelled = true;
  }
  check(
    cancelled && transport.calls == 1,
    'transport cancellation is not retried',
  );

  final directory = await Directory.systemTemp.createTemp('embedding-gate-');
  final path = '${directory.path}/scheduler.db';
  var db = await connect(path);
  final durable = EmbeddingScheduler(
    SqliteEmbeddingThrottleStore(db),
    'durable',
    now: clock.now,
    random: () => 0,
  );
  await durable.claim('owner', 1, false);
  await durable.finish(
    'owner',
    limits: EmbeddingLimitHeaders({'retry-after': '600'}, clock.now()),
    throttled: true,
  );
  final beforeRestart = await durable.nextEligible();
  await db.close();
  db = await connect(path);
  final afterRestart = EmbeddingScheduler(
    SqliteEmbeddingThrottleStore(db),
    'durable',
    now: clock.now,
  );
  check(
    await afterRestart.nextEligible() == beforeRestart &&
        !(await afterRestart.claim('new-owner', 1, false)).granted,
    'SQLite cooldown survives restart exactly',
  );
  await db.close();
  final ready1 = ReceivePort(), ready2 = ReceivePort(), results = ReceivePort();
  await Isolate.spawn(contender, (path, ready1.sendPort, results.sendPort));
  final p1 = await ready1.first as SendPort;
  await Isolate.spawn(contender, (path, ready2.sendPort, results.sendPort));
  final p2 = await ready2.first as SendPort;
  p1.send('claim');
  p2.send('claim');
  final grants = await results.take(2).toList();
  check(
    grants.where((v) => v == true).length == 1 &&
        grants.where((v) => v == false).length == 1,
    'real SQLite transactions serialize independent isolate requests: $grants',
  );
  ready1.close();
  ready2.close();
  results.close();
  final progress = RagIndexProgress(
    bookId: 'book',
    status: RagIndexStatus.waiting,
    totalChunks: 3653,
    indexedChunks: 3603,
    lastUpdated: clock.now(),
    nextRetryAt: beforeRestart,
    waitReason: 'provider_limit',
  );
  final restored = RagIndexProgress.fromJson(progress.toJson());
  check(
    restored.isWaiting &&
        !restored.hasError &&
        restored.indexedChunks == 3603 &&
        restored.nextRetryAt == beforeRestart,
    'waiting checkpoint round-trip preserves completed work',
  );
  check(
    embeddingWaitLabel(
      'provider_limit',
      french: false,
      remainingSeconds: 12,
    ).endsWith('12 s'),
    'English provider cooldown includes countdown',
  );
  check(
    embeddingWaitLabel(
      'network',
      french: true,
      remainingSeconds: 3,
    ).contains('connexion'),
    'French connection wait is distinct from rate limiting',
  );
  check(
    !embeddingWaitLabel(
      'retry_budget',
      french: false,
      remainingSeconds: -1,
    ).contains('-1'),
    'elapsed cooldown never shows negative seconds',
  );
  print('$checks embedding scheduler checks passed');
}
