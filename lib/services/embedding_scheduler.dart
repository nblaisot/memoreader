import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Sanitized provider failures: no raw response bodies, inputs or credentials.
class EmbeddingProviderException implements Exception {
  const EmbeddingProviderException(
    this.kind,
    this.message, {
    this.status,
    this.code,
    this.requestId,
  });
  final String kind, message;
  final int? status;
  final String? code, requestId;
  @override
  String toString() => 'Embedding $kind: $message';
}

class EmbeddingDeferredException implements Exception {
  const EmbeddingDeferredException(this.nextEligibleAt, this.reason);
  final DateTime nextEligibleAt;
  final String reason;
  @override
  String toString() => 'Embedding preparation waiting: $reason';
}

class EmbeddingSchedulingContext {
  static Future<T> run<T>({
    required Future<T> Function() action,
    required Future<void> Function(DateTime until, String reason) onWait,
    required Future<void> Function() onResume,
  }) => runZoned(
    action,
    zoneValues: {#embeddingWait: onWait, #embeddingResume: onResume},
  );
  static Future<void> waiting(DateTime until, String reason) async {
    final callback =
        Zone.current[#embeddingWait]
            as Future<void> Function(DateTime, String)?;
    await callback?.call(until, reason);
  }

  static Future<void> resumed() async {
    final callback = Zone.current[#embeddingResume] as Future<void> Function()?;
    await callback?.call();
  }
}

Duration? parseEmbeddingDelay(String? value, DateTime now) {
  if (value == null) return null;
  final seconds = double.tryParse(value.trim());
  if (seconds != null && seconds.isFinite && seconds >= 0) {
    return Duration(microseconds: (seconds * 1000000).ceil());
  }
  final matches = RegExp(r'(\d+(?:\.\d+)?)(ms|s|m|h)').allMatches(value.trim());
  if (matches.isNotEmpty && matches.map((m) => m[0]).join() == value.trim()) {
    var micros = 0.0;
    for (final m in matches) {
      final scale = {
        'ms': 1000,
        's': 1000000,
        'm': 60000000,
        'h': 3600000000,
      }[m[2]]!;
      micros += double.parse(m[1]!) * scale;
    }
    return Duration(microseconds: micros.ceil());
  }
  try {
    final delay = HttpDate.parse(value).difference(now.toUtc());
    return delay.isNegative ? Duration.zero : delay;
  } catch (_) {
    return null;
  }
}

class EmbeddingLimitHeaders {
  EmbeddingLimitHeaders(Map<String, String> headers, this.now)
    : headers = headers.map((k, v) => MapEntry(k.toLowerCase(), v));
  final Map<String, String> headers;
  final DateTime now;
  int? number(String key) => int.tryParse(headers[key] ?? '');
  int reset(String key) =>
      now.millisecondsSinceEpoch +
      (parseEmbeddingDelay(headers[key], now)?.inMilliseconds ?? 0);
  Duration? get retryAfter {
    final delays = <Duration>[
      if (parseEmbeddingDelay(headers['retry-after'], now)
          case final Duration d)
        d,
      for (final pair in [
        ('x-ratelimit-remaining-requests', 'x-ratelimit-reset-requests'),
        ('x-ratelimit-remaining-tokens', 'x-ratelimit-reset-tokens'),
        (
          'x-ratelimit-remaining-project-tokens',
          'x-ratelimit-reset-project-tokens',
        ),
      ])
        if (number(pair.$1) == null || number(pair.$1)! <= 0)
          if (parseEmbeddingDelay(headers[pair.$2], now) case final Duration d)
            d,
    ];
    return delays.isEmpty ? null : delays.reduce((a, b) => a > b ? a : b);
  }

  Map<String, Object?> get diagnostics => {
    for (final key in [
      'retry-after',
      'x-ratelimit-limit-requests',
      'x-ratelimit-remaining-requests',
      'x-ratelimit-reset-requests',
      'x-ratelimit-limit-tokens',
      'x-ratelimit-remaining-tokens',
      'x-ratelimit-reset-tokens',
      'x-ratelimit-remaining-project-tokens',
      'x-ratelimit-reset-project-tokens',
    ])
      if (headers[key] != null) key: headers[key],
  };
}

/// Every mutation is atomic across processes/isolates in the persistent store.
abstract interface class EmbeddingThrottleStore {
  Future<T> access<T>(
    String bucket,
    T Function(Map<String, dynamic> state) update,
  );
}

class MemoryEmbeddingThrottleStore implements EmbeddingThrottleStore {
  final _states = <String, Map<String, dynamic>>{};
  @override
  Future<T> access<T>(
    String bucket,
    T Function(Map<String, dynamic>) update,
  ) async => update(_states.putIfAbsent(bucket, () => {}));
}

class EmbeddingPermit {
  const EmbeddingPermit(this.granted, this.until, this.reason);
  final bool granted;
  final DateTime until;
  final String reason;
}

class EmbeddingScheduler {
  EmbeddingScheduler(
    this.store,
    this.bucket, {
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    double Function()? random,
  }) : now = now ?? DateTime.now,
       sleep = sleep ?? Future<void>.delayed,
       random = random ?? math.Random().nextDouble;
  final EmbeddingThrottleStore store;
  final String bucket;
  final DateTime Function() now;
  final Future<void> Function(Duration) sleep;
  final double Function() random;

  Future<EmbeddingPermit> claim(String owner, int tokens, bool interactive) =>
      store.access(bucket, (s) {
        final at = now().millisecondsSinceEpoch;
        if (interactive) s['priorityUntil'] = at + 5000;
        var until = (s['nextAllowed'] as int?) ?? 0;
        var reason = s['waitReason'] as String? ?? 'provider_limit';
        if ((s['leaseUntil'] as int? ?? 0) > at) {
          until = math.max(until, math.min(s['leaseUntil'] as int, at + 500));
          reason = 'active_request';
        }
        for (final suffix in ['Tokens', 'ProjectTokens']) {
          final remaining = s['remaining$suffix'] as int?;
          if (remaining != null &&
              remaining < tokens &&
              (s['reset$suffix'] as int? ?? 0) > at) {
            until = math.max(until, s['reset$suffix'] as int);
            reason = 'token_budget';
          }
        }
        if (!interactive && (s['priorityUntil'] as int? ?? 0) > at) {
          until = math.max(
            until,
            math.min(s['priorityUntil'] as int, at + 500),
          );
          reason = 'interactive_priority';
        }
        if (until > at)
          return EmbeddingPermit(
            false,
            DateTime.fromMillisecondsSinceEpoch(until),
            reason,
          );
        s['owner'] = owner;
        s['leaseUntil'] = at + 180000;
        if (interactive) s['priorityUntil'] = 0;
        return EmbeddingPermit(true, now(), 'ready');
      });

  Future<void> finish(
    String owner, {
    EmbeddingLimitHeaders? limits,
    bool success = false,
    bool throttled = false,
    String failureReason = 'provider_limit',
  }) => store.access(bucket, (s) {
    if (s['owner'] != owner) return;
    s['owner'] = null;
    s['leaseUntil'] = 0;
    if (limits != null) {
      for (final suffix in ['tokens', 'project-tokens']) {
        final name = suffix == 'tokens' ? 'Tokens' : 'ProjectTokens';
        final remaining = limits.number('x-ratelimit-remaining-$suffix');
        s['remaining$name'] = remaining;
        s['reset$name'] = limits.reset('x-ratelimit-reset-$suffix');
      }
      if (limits.number('x-ratelimit-remaining-requests') == 0) {
        s['nextAllowed'] = math.max(
          s['nextAllowed'] as int? ?? 0,
          limits.reset('x-ratelimit-reset-requests'),
        );
      }
    }
    if (success) s['failures'] = 0;
    if (throttled) {
      final count = (s['failures'] as int? ?? 0) + 1;
      s['failures'] = count;
      final floor = Duration(
        seconds: math.min(120, 2 * (1 << math.min(count - 1, 6))),
      );
      final server = limits?.retryAfter ?? Duration.zero;
      final base = server > floor ? server : floor;
      final delay =
          base + Duration(milliseconds: 100 + (random() * 400).floor());
      s['nextAllowed'] = math.max(
        s['nextAllowed'] as int? ?? 0,
        now().millisecondsSinceEpoch + delay.inMilliseconds,
      );
    }
  });

  Future<void> acquire(
    String owner,
    int tokens,
    bool interactive,
    DateTime deadline, {
    Future<void>? abort,
  }) async {
    var cancelled = false;
    abort?.then((_) => cancelled = true);
    await Future<void>.value();
    while (true) {
      if (cancelled)
        throw const EmbeddingProviderException(
          'cancelled',
          'Request cancelled.',
        );
      if (!now().isBefore(deadline)) {
        final next = await nextEligible();
        final floor = now().add(const Duration(seconds: 30));
        throw EmbeddingDeferredException(
          next.isAfter(floor) ? next : floor,
          'retry_budget',
        );
      }
      final permit = await claim(owner, tokens, interactive);
      if (permit.granted) {
        if (cancelled)
          throw const EmbeddingProviderException(
            'cancelled',
            'Request cancelled.',
          );
        await EmbeddingSchedulingContext.resumed();
        return;
      }
      await EmbeddingSchedulingContext.waiting(permit.until, permit.reason);
      if (permit.until.isAfter(deadline))
        throw EmbeddingDeferredException(permit.until, permit.reason);
      final wait = permit.until.difference(now());
      final slice = wait > const Duration(seconds: 20)
          ? const Duration(seconds: 20)
          : wait;
      await Future.any([
        sleep(slice.isNegative ? Duration.zero : slice),
        if (abort != null)
          abort.then<void>(
            (_) => throw const EmbeddingProviderException(
              'cancelled',
              'Request cancelled.',
            ),
          ),
      ]);
    }
  }

  Future<DateTime> nextEligible() => store.access(
    bucket,
    (s) => DateTime.fromMillisecondsSinceEpoch(
      s['nextAllowed'] as int? ?? now().millisecondsSinceEpoch,
    ),
  );
}
