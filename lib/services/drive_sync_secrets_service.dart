import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores the Drive sync passphrase in the platform secure store and tracks
/// whether encrypted API key upload is enabled ([SharedPreferences] only for
/// the flag — never the passphrase).
class DriveSyncSecretsService {
  DriveSyncSecretsService._();

  static const _securePassphraseKey = 'drive_sync_api_keys_passphrase';
  static const _prefsEncryptionEnabled = 'drive_api_keys_cloud_encryption_enabled';
  static const _prefsLegacyPlaintextHintKey =
      'drive_api_keys_legacy_plaintext_sync_hint_dismissed';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// Whether the user wants API keys on Drive to be stored encrypted.
  /// Upload is skipped unless this is true **and** a passphrase is set.
  ///
  /// Defaults to **true** when never set, so new installs encrypt by default;
  /// users may explicitly turn encryption off (API keys then are not uploaded).
  static Future<bool> isCloudEncryptionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsEncryptionEnabled) ?? true;
  }

  static Future<void> setCloudEncryptionEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    if (enabled) {
      await prefs.setBool(_prefsEncryptionEnabled, true);
    } else {
      await prefs.setBool(_prefsEncryptionEnabled, false);
    }
  }

  /// True if a non-empty passphrase exists in secure storage.
  static Future<bool> hasPassphraseConfigured() async {
    final p = await _storage.read(key: _securePassphraseKey);
    return p != null && p.isNotEmpty;
  }

  static Future<String?> getPassphrase() async {
    return _storage.read(key: _securePassphraseKey);
  }

  static Future<void> setPassphrase(String passphrase) async {
    await _storage.write(key: _securePassphraseKey, value: passphrase);
  }

  /// Removes the passphrase from secure storage. Does not change the
  /// encryption-enabled flag; call [setCloudEncryptionEnabled(false)] if needed.
  static Future<void> clearPassphrase() async {
    await _storage.delete(key: _securePassphraseKey);
  }

  /// Disables cloud encryption and deletes the stored passphrase.
  static Future<void> disableEncryptionAndClearPassphrase() async {
    await clearPassphrase();
    await setCloudEncryptionEnabled(false);
  }

  /// One-time UI hint: older installs may have uploaded plaintext keys to Drive.
  static Future<bool> wasLegacyPlaintextHintDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsLegacyPlaintextHintKey) ?? false;
  }

  static Future<void> dismissLegacyPlaintextHint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsLegacyPlaintextHintKey, true);
  }

  /// Ready to encrypt uploads: feature on and passphrase present.
  static Future<bool> canEncryptApiKeysForUpload() async {
    if (!await isCloudEncryptionEnabled()) return false;
    return hasPassphraseConfigured();
  }
}
