import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/codex_auth_service.dart';
import 'package:memoreader/services/codex_embedding_service.dart';
import 'package:memoreader/services/mistral_embedding_service.dart';
import 'package:memoreader/services/openai_embedding_service.dart';
import 'package:memoreader/services/rag_embedding_service_factory.dart';
import 'package:memoreader/services/summary_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

CodexAuthService _signedOutAuth() => CodexAuthService(
      readStoredJson: () async => null,
      writeStoredJson: (_) async {},
      deleteStoredJson: () async {},
    );

CodexAuthService _signedInAuth() {
  final stored = jsonEncode({
    'access_token': 't',
    'refresh_token': 'r',
    'expires_at_ms':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
  });
  return CodexAuthService(
    readStoredJson: () async => stored,
    writeStoredJson: (_) async {},
    deleteStoredJson: () async {},
  );
}

void main() {
  test('Codex provider uses CodexEmbeddingService when signed in', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
    });
    final prefs = await SharedPreferences.getInstance();
    final config = SummaryConfigService(prefs, codexAuth: _signedInAuth());

    final service =
        await RagEmbeddingServiceFactory.create(prefs, configService: config);
    expect(service, isA<CodexEmbeddingService>());
  });

  test('Codex provider falls back to OpenAI key when not signed in', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
      'openai_api_key': 'sk-test',
    });
    final prefs = await SharedPreferences.getInstance();
    final config = SummaryConfigService(prefs, codexAuth: _signedOutAuth());
    final service =
        await RagEmbeddingServiceFactory.create(prefs, configService: config);
    expect(service, isA<OpenAIEmbeddingService>());
  });

  test('Codex provider falls back to Mistral when no OpenAI key', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
      'mistral_api_key': 'mk-test',
    });
    final prefs = await SharedPreferences.getInstance();
    final config = SummaryConfigService(prefs, codexAuth: _signedOutAuth());
    final service =
        await RagEmbeddingServiceFactory.create(prefs, configService: config);
    expect(service, isA<MistralEmbeddingService>());
  });

  test('unavailableMessage mentions sign-in for Codex without credentials',
      () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
    });
    final prefs = await SharedPreferences.getInstance();
    final config = SummaryConfigService(prefs, codexAuth: _signedOutAuth());
    final msg = await RagEmbeddingServiceFactory.unavailableMessage(
      prefs,
      configService: config,
    );
    expect(msg, contains('Sign in'));
    expect(await config.isCodexConfigured(), isFalse);
  });
}
