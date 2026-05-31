import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/codex_auth_service.dart';
import 'package:memoreader/services/codex_summary_service.dart';
import 'package:memoreader/services/summary_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('setProvider accepts openai_codex', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final config = SummaryConfigService(prefs);
    await config.setProvider(SummaryConfigService.providerCodex);
    expect(config.getProvider(), SummaryConfigService.providerCodex);
  });

  test('getSummaryService returns CodexSummaryService when configured', () async {
    SharedPreferences.setMockInitialValues({
      SummaryConfigService.providerKey: SummaryConfigService.providerCodex,
    });
    final prefs = await SharedPreferences.getInstance();

    final auth = CodexAuthService(
      readStoredJson: () async =>
          '{"access_token":"t","refresh_token":"r","expires_at_ms":${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}}',
      writeStoredJson: (_) async {},
      deleteStoredJson: () async {},
    );

    final config = SummaryConfigService(prefs, codexAuth: auth);
    final service = await config.getSummaryService();
    expect(service, isA<CodexSummaryService>());
  });
}
