import 'package:shared_preferences/shared_preferences.dart';

import 'rag_embedding_service.dart';

enum ProviderFailureKind {
  authentication,
  authorization,
  quota,
  modelUnavailable,
  timeout,
  network,
  invalidResponse,
  unknown,
}

class ProviderCapabilityException implements Exception {
  const ProviderCapabilityException(this.kind, this.message);
  final ProviderFailureKind kind;
  final String message;

  @override
  String toString() => 'Embedding capability ${kind.name}: $message';
}

/// Verifies real embedding capability instead of equating a stored credential
/// with provider/model/network availability.
class EmbeddingCapabilityService {
  EmbeddingCapabilityService(this._prefs);

  static const _ttl = Duration(hours: 24);
  final SharedPreferences _prefs;

  Future<void> ensureAvailable(EmbeddingService service) async {
    final identity =
        '${service.providerName}:${service.modelName}:${service.embeddingDimensions}';
    final key = 'rag_capability_${identity.hashCode}';
    final checkedAtMillis = _prefs.getInt(key);
    if (checkedAtMillis != null) {
      final checkedAt = DateTime.fromMillisecondsSinceEpoch(checkedAtMillis);
      if (DateTime.now().difference(checkedAt) < _ttl) return;
    }

    late final List<double> vector;
    try {
      vector = await service
          .embedText('MemoReader capability check')
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      final message = error.toString();
      throw ProviderCapabilityException(_classify(message), message);
    }
    if (vector.length != service.embeddingDimensions) {
      throw ProviderCapabilityException(
        ProviderFailureKind.invalidResponse,
        '${service.providerName}/${service.modelName} returned '
        '${vector.length} dimensions; ${service.embeddingDimensions} expected.',
      );
    }
    await _prefs.setInt(key, DateTime.now().millisecondsSinceEpoch);
  }

  static ProviderFailureKind _classify(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('timeout')) return ProviderFailureKind.timeout;
    if (lower.contains('401') || lower.contains('invalid api key')) {
      return ProviderFailureKind.authentication;
    }
    if (lower.contains('403') || lower.contains('permission')) {
      return ProviderFailureKind.authorization;
    }
    if (lower.contains('429') || lower.contains('rate limit') || lower.contains('quota')) {
      return ProviderFailureKind.quota;
    }
    if (lower.contains('model') && (lower.contains('not found') || lower.contains('unavailable'))) {
      return ProviderFailureKind.modelUnavailable;
    }
    if (lower.contains('socket') || lower.contains('network') || lower.contains('connection')) {
      return ProviderFailureKind.network;
    }
    return ProviderFailureKind.unknown;
  }
}
