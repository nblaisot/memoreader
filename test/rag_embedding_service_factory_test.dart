import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/embedding_config_service.dart';
import 'package:memoreader/services/mistral_embedding_service.dart';
import 'package:memoreader/services/openai_embedding_service.dart';
import 'package:memoreader/services/rag_embedding_service_factory.dart';
import 'package:memoreader/services/summary_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Codex answer selection alone does not provide embeddings', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
    });
    final prefs = await SharedPreferences.getInstance();

    final service = await RagEmbeddingServiceFactory.create(prefs);

    expect(service, isNull);
    expect(
      await RagEmbeddingServiceFactory.unavailableMessage(prefs),
      contains('Platform'),
    );
  });

  test('legacy configuration migrates to OpenAI Platform key', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
      'openai_api_key': 'sk-test',
    });
    final prefs = await SharedPreferences.getInstance();

    final service = await RagEmbeddingServiceFactory.create(prefs);

    expect(service, isA<OpenAIEmbeddingService>());
  });

  test('legacy configuration falls back to Mistral key', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
      'mistral_api_key': 'mk-test',
    });
    final prefs = await SharedPreferences.getInstance();

    final service = await RagEmbeddingServiceFactory.create(prefs);

    expect(service, isA<MistralEmbeddingService>());
  });

  test(
    'explicit embedding provider is independent from answer provider',
    () async {
      SharedPreferences.setMockInitialValues({
        SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
        EmbeddingConfigService.providerKey:
            EmbeddingConfigService.providerMistral,
        'openai_api_key': 'sk-test',
        'mistral_api_key': 'mk-test',
      });
      final prefs = await SharedPreferences.getInstance();

      final service = await RagEmbeddingServiceFactory.create(prefs);

      expect(service, isA<MistralEmbeddingService>());
    },
  );
}
