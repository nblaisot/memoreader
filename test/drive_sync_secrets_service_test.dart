import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/drive_sync_secrets_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('DriveSyncSecretsService — encryption flag', () {
    test('isCloudEncryptionEnabled defaults to true when never set', () async {
      expect(await DriveSyncSecretsService.isCloudEncryptionEnabled(), isTrue);
    });

    test('setCloudEncryptionEnabled(false) persists false', () async {
      await DriveSyncSecretsService.setCloudEncryptionEnabled(false);
      expect(await DriveSyncSecretsService.isCloudEncryptionEnabled(), isFalse);
    });

    test('setCloudEncryptionEnabled(true) persists true', () async {
      await DriveSyncSecretsService.setCloudEncryptionEnabled(false);
      await DriveSyncSecretsService.setCloudEncryptionEnabled(true);
      expect(await DriveSyncSecretsService.isCloudEncryptionEnabled(), isTrue);
    });
  });

  group('DriveSyncSecretsService — passphrase', () {
    test('hasPassphraseConfigured returns false when no passphrase set', () async {
      expect(await DriveSyncSecretsService.hasPassphraseConfigured(), isFalse);
    });

    test('getPassphrase returns null when no passphrase set', () async {
      expect(await DriveSyncSecretsService.getPassphrase(), isNull);
    });

    test('setPassphrase and getPassphrase round-trip', () async {
      await DriveSyncSecretsService.setPassphrase('my-secret-123');
      expect(await DriveSyncSecretsService.getPassphrase(), 'my-secret-123');
    });

    test('hasPassphraseConfigured returns true after setting passphrase', () async {
      await DriveSyncSecretsService.setPassphrase('hunter2');
      expect(await DriveSyncSecretsService.hasPassphraseConfigured(), isTrue);
    });

    test('clearPassphrase removes the passphrase', () async {
      await DriveSyncSecretsService.setPassphrase('to-be-cleared');
      await DriveSyncSecretsService.clearPassphrase();
      expect(await DriveSyncSecretsService.getPassphrase(), isNull);
      expect(await DriveSyncSecretsService.hasPassphraseConfigured(), isFalse);
    });

    test('setPassphrase overwrites a previously set passphrase', () async {
      await DriveSyncSecretsService.setPassphrase('old-pass');
      await DriveSyncSecretsService.setPassphrase('new-pass');
      expect(await DriveSyncSecretsService.getPassphrase(), 'new-pass');
    });
  });

  group('DriveSyncSecretsService — disableEncryptionAndClearPassphrase', () {
    test('clears passphrase and sets encryption to false', () async {
      await DriveSyncSecretsService.setPassphrase('some-pass');
      await DriveSyncSecretsService.setCloudEncryptionEnabled(true);

      await DriveSyncSecretsService.disableEncryptionAndClearPassphrase();

      expect(await DriveSyncSecretsService.getPassphrase(), isNull);
      expect(await DriveSyncSecretsService.isCloudEncryptionEnabled(), isFalse);
    });
  });

  group('DriveSyncSecretsService — canEncryptApiKeysForUpload', () {
    test('returns false when encryption is disabled', () async {
      await DriveSyncSecretsService.setCloudEncryptionEnabled(false);
      await DriveSyncSecretsService.setPassphrase('irrelevant');
      expect(await DriveSyncSecretsService.canEncryptApiKeysForUpload(), isFalse);
    });

    test('returns false when encryption is enabled but no passphrase', () async {
      await DriveSyncSecretsService.setCloudEncryptionEnabled(true);
      expect(await DriveSyncSecretsService.canEncryptApiKeysForUpload(), isFalse);
    });

    test('returns true when encryption enabled and passphrase set', () async {
      await DriveSyncSecretsService.setCloudEncryptionEnabled(true);
      await DriveSyncSecretsService.setPassphrase('secure-pass');
      expect(await DriveSyncSecretsService.canEncryptApiKeysForUpload(), isTrue);
    });

    test('returns false by default (encryption on but no passphrase)', () async {
      // Default: encryption enabled, no passphrase → cannot encrypt
      expect(await DriveSyncSecretsService.canEncryptApiKeysForUpload(), isFalse);
    });
  });

  group('DriveSyncSecretsService — legacy plaintext hint', () {
    test('wasLegacyPlaintextHintDismissed returns false by default', () async {
      expect(
        await DriveSyncSecretsService.wasLegacyPlaintextHintDismissed(),
        isFalse,
      );
    });

    test('dismissLegacyPlaintextHint persists dismissed state', () async {
      await DriveSyncSecretsService.dismissLegacyPlaintextHint();
      expect(
        await DriveSyncSecretsService.wasLegacyPlaintextHintDismissed(),
        isTrue,
      );
    });
  });
}
