import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'rag_request_scope.dart';
import 'rag_generation.dart';
import 'rag_embedding_service.dart';
import 'rag_token_budget.dart';
import 'embedding_scheduler.dart';
export 'rag_embedding_service.dart' show EmbeddingRateLimitException;

/// Every embedding request uses the same persistent rate gate in production.
/// Test callers can inject a client, clock and store without accessing secrets.
abstract class ScheduledHttpEmbeddingService
    implements EmbeddingService, RetryManagedEmbeddingService {
  ScheduledHttpEmbeddingService(
    this.apiKey, {
    required this.model,
    http.Client? client,
    Future<EmbeddingThrottleStore> Function()? throttleStore,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    double Function()? random,
  }) : _client = client ?? _sharedClient,
       _store = throttleStore ?? (() async => _memory),
       _now = now ?? DateTime.now,
       _sleep = sleep,
       _random = random;
  final String apiKey, model;
  final http.Client _client;
  final Future<EmbeddingThrottleStore> Function() _store;
  final DateTime Function() _now;
  final Future<void> Function(Duration)? _sleep;
  final double Function()? _random;
  static final _sharedClient = createRagHttpClient();
  static final _memory = MemoryEmbeddingThrottleStore();
  static int _serial = 0;
  @override
  String get schedulingIdentity =>
      sha256.convert(utf8.encode('$providerName:$model:$apiKey')).toString();
  String get endpoint;
  int get maxBatchInputs => 2048;
  @override
  String get providerName;
  @override
  String get modelName => model;
  @override
  int get embeddingDimensions;
  @override
  int get maxTokensPerInput;
  @override
  Future<bool> isAvailable() async => apiKey.isNotEmpty;
  @override
  Future<Float32List> embedText(String text) async =>
      (await embedTexts([text])).first;

  @override
  Future<List<Float32List>> embedTexts(List<String> texts) async {
    final result = <Float32List>[];
    for (var i = 0; i < texts.length; i += maxBatchInputs) {
      result.addAll(
        await _embedBatch(
          texts.sublist(i, (i + maxBatchInputs).clamp(0, texts.length)),
        ),
      );
    }
    return result;
  }

  Future<List<Float32List>> _embedBatch(List<String> texts) async {
    if (apiKey.isEmpty)
      throw EmbeddingProviderException(
        'authentication',
        'Configure a $providerName API key.',
      );
    if (texts.isEmpty) return [];
    final bucket = schedulingIdentity;
    final scheduler = EmbeddingScheduler(
      await _store(),
      bucket,
      now: _now,
      sleep: _sleep,
      random: _random,
    );
    final interactive = RagRequestScope.active;
    final deadline = _now().add(
      interactive ? const Duration(minutes: 2) : const Duration(minutes: 10),
    );
    final tokens = texts.fold<int>(
      0,
      (n, text) => n + RagTokenBudget.count(text),
    );
    final owner = '$pid:${const Uuid().v4()}:${_serial++}';
    final abort = RagRequestScope.abort;
    for (var attempt = 1; attempt <= 8; attempt++) {
      EmbeddingLimitHeaders? limits;
      DateTime? dispatchedAt;
      var success = false, retry = false;
      var failureReason = 'provider_limit';
      try {
        await scheduler.acquire(
          owner,
          tokens,
          interactive,
          deadline,
          abort: abort,
        );
        final remaining = deadline.difference(_now());
        if (remaining <= Duration.zero)
          throw EmbeddingDeferredException(
            _now().add(const Duration(seconds: 30)),
            'retry_budget',
          );
        dispatchedAt = _now();
        final cancelled = Completer<void>();
        final request =
            http.AbortableRequest(
                'POST',
                Uri.parse(endpoint),
                abortTrigger: abort == null
                    ? cancelled.future
                    : Future.any([abort, cancelled.future]),
              )
              ..headers.addAll({
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              })
              ..body = jsonEncode({'model': model, 'input': texts});
        final response =
            await (() async => http.Response.fromStream(
              await _client.send(request),
            ))().timeout(
              remaining < const Duration(seconds: 120)
                  ? remaining
                  : const Duration(seconds: 120),
              onTimeout: () {
                if (!cancelled.isCompleted) cancelled.complete();
                throw TimeoutException('Embedding response timed out');
              },
            );
        limits = EmbeddingLimitHeaders(response.headers, _now());
        final requestId = response.headers['x-request-id'];
        Map<String, dynamic> body;
        try {
          body = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          if (response.statusCode == 200) {
            throw const EmbeddingProviderException(
              'invalid_response',
              'The provider returned an invalid response.',
            );
          }
          body = {};
        }
        final error = body['error'] is Map ? body['error'] as Map : const {};
        final code = error['code'] is String ? error['code'] as String : null;
        final terminalQuota =
            response.statusCode == 402 ||
            [
              'insufficient_quota',
              'billing_hard_limit_reached',
              'billing_not_active',
              'usage_limit_reached',
            ].contains(code) ||
            error['type'] == 'insufficient_quota';
        final metadata = <String, Object?>{
          'provider': providerName,
          'model': model,
          'attempt': attempt,
          'batchSize': texts.length,
          'estimatedTokens': tokens,
          'httpStatus': response.statusCode,
          'requestMs': _now().difference(dispatchedAt).inMilliseconds,
          'requestId': requestId,
          'errorCode': code,
          'limits': limits.diagnostics,
          if (body['usage'] is Map)
            'usage': {
              for (final key in ['prompt_tokens', 'total_tokens'])
                if ((body['usage'] as Map)[key] is num)
                  key: (body['usage'] as Map)[key],
            },
        };
        RagTrace.record('embedding_response', metadata);
        if (!interactive && !const bool.fromEnvironment('dart.vm.product')) {
          // Debug metadata only; inputs and credentials are never logged.
          // ignore: avoid_print
          print(
            '[RAG] embedding provider=$providerName model=$model attempt=$attempt batch=${texts.length} estimatedTokens=$tokens http=${response.statusCode} code=$code requestId=$requestId usage=${metadata['usage']} requestMs=${metadata['requestMs']} limits=${limits.diagnostics}',
          );
        }
        if (terminalQuota)
          throw EmbeddingProviderException(
            'quota',
            '$providerName credits or billing limits require attention.',
            status: response.statusCode,
            code: code,
            requestId: requestId,
          );
        if ([429, 408, 500, 502, 503, 504].contains(response.statusCode)) {
          retry = true;
          failureReason = response.statusCode == 429
              ? 'provider_limit'
              : 'provider_busy';
        } else if (response.statusCode != 200) {
          final kind = response.statusCode == 401
              ? 'authentication'
              : response.statusCode == 403
              ? 'authorization'
              : response.statusCode == 404
              ? 'model_unavailable'
              : 'invalid_input';
          throw EmbeddingProviderException(
            kind,
            '$providerName embedding request rejected (HTTP ${response.statusCode}).',
            status: response.statusCode,
            code: code,
            requestId: requestId,
          );
        } else {
          final items = body['data'];
          if (items is! List || items.length != texts.length)
            throw const EmbeddingProviderException(
              'invalid_response',
              'Embedding count does not match the requested batch.',
            );
          final vectors = List<Float32List?>.filled(texts.length, null);
          for (final item in items) {
            if (item is! Map ||
                item['index'] is! int ||
                item['embedding'] is! List)
              throw const EmbeddingProviderException(
                'invalid_response',
                'Invalid embedding structure.',
              );
            final index = item['index'] as int;
            final values = item['embedding'] as List;
            if (index < 0 ||
                index >= vectors.length ||
                vectors[index] != null ||
                values.length != embeddingDimensions ||
                values.any((v) => v is! num || !v.isFinite)) {
              throw const EmbeddingProviderException(
                'invalid_response',
                'Invalid embedding dimensions or response index.',
              );
            }
            final vector = Float32List.fromList(
              values.cast<num>().map((v) => v.toDouble()).toList(),
            );
            if (vector.any((v) => !v.isFinite)) {
              throw const EmbeddingProviderException(
                'invalid_response',
                'Embedding values exceed float32 range.',
              );
            }
            vectors[index] = vector;
          }
          success = true;
          return vectors.cast<Float32List>();
        }
      } on SocketException {
        retry = true;
        failureReason = 'network';
      } on TimeoutException {
        retry = true;
        failureReason = 'timeout';
      } on http.RequestAbortedException {
        rethrow;
      } on http.ClientException {
        retry = true;
        failureReason = 'network';
      } finally {
        await scheduler.finish(
          owner,
          limits: limits,
          success: success,
          throttled: retry,
          failureReason: failureReason,
        );
      }
      if (attempt == 8) {
        var next = await scheduler.nextEligible();
        if (!next.isAfter(_now()))
          next = _now().add(const Duration(seconds: 30));
        throw EmbeddingDeferredException(next, 'retry_budget');
      }
      final next = await scheduler.nextEligible();
      RagTrace.record('embedding_cooldown', {
        'attempt': attempt,
        'nextEligibleAt': next.toUtc().toIso8601String(),
        'delayMs': next.difference(_now()).inMilliseconds,
        'kind': failureReason,
      });
      if (!interactive)
        // ignore: avoid_print
        print(
          '[RAG] embedding cooldown attempt=$attempt kind=$failureReason delayMs=${next.difference(_now()).inMilliseconds} nextEligibleAt=${next.toUtc().toIso8601String()}',
        );
    }
    throw StateError('Unreachable embedding retry state');
  }
}
