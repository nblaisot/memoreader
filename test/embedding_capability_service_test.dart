import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/embedding_capability_service.dart';
import 'package:memoreader/services/rag_embedding_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EmbeddingFake implements EmbeddingService {
  int calls = 0;
  int returnedDimensions = 3;

  @override
  int get embeddingDimensions => 3;
  @override
  int get maxTokensPerInput => 100;
  @override
  String get modelName => 'model';
  @override
  String get providerName => 'provider';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<Float32List> embedText(String text) async {
    calls++;
    return Float32List(returnedDimensions);
  }

  @override
  Future<List<Float32List>> embedTexts(List<String> texts) async =>
      Future.wait(texts.map(embedText));
}

void main() {
  test('probes real dimensions and caches success for 24 hours', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fake = _EmbeddingFake();
    final probe = EmbeddingCapabilityService(prefs);

    await probe.ensureAvailable(fake);
    await probe.ensureAvailable(fake);
    expect(fake.calls, 1);
  });

  test('rejects a model returning incompatible dimensions', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _EmbeddingFake()..returnedDimensions = 2;
    final prefs = await SharedPreferences.getInstance();
    expect(
      () => EmbeddingCapabilityService(prefs).ensureAvailable(fake),
      throwsA(
        isA<ProviderCapabilityException>().having(
          (error) => error.kind,
          'kind',
          ProviderFailureKind.invalidResponse,
        ),
      ),
    );
  });
}
