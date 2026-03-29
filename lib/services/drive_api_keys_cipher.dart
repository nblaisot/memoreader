import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Format version for ciphertext uploaded to Google Drive.
const int kDriveApiKeysCryptoVersion = 1;

/// PBKDF2-HMAC-SHA256 iteration count (OWASP-style; bump [kDriveApiKeysCryptoVersion] if changed).
const int kDriveApiKeysPbkdf2Iterations = 600000;

const String kDriveApiKeysKdfId = 'pbkdf2-hmac-sha256';

/// Thrown when the blob is malformed or the passphrase is wrong (authentication failure).
class DriveApiKeysDecryptException implements Exception {
  final String message;

  DriveApiKeysDecryptException(this.message);

  @override
  String toString() => 'DriveApiKeysDecryptException: $message';
}

/// Client-side encryption for API key payloads synced to Drive.
class DriveApiKeysCipher {
  DriveApiKeysCipher._();

  static final Pbkdf2 _pbkdf2 = Pbkdf2.hmacSha256(
    iterations: kDriveApiKeysPbkdf2Iterations,
    bits: 256,
  );

  static final AesGcm _aes = AesGcm.with256bits();

  /// Random salt length for PBKDF2 (stored in plaintext beside the blob).
  static const int saltLength = 16;

  /// Encrypts [plaintextUtf8] and returns a JSON-serialisable map for Drive.
  static Future<Map<String, dynamic>> encrypt({
    required List<int> plaintextUtf8,
    required String passphrase,
  }) async {
    final saltData = SecretKeyData.random(length: saltLength);
    final salt = await saltData.extractBytes();
    final nonce = _aes.newNonce();

    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );

    final box = await _aes.encrypt(
      plaintextUtf8,
      secretKey: secretKey,
      nonce: nonce,
    );

    return {
      'v': kDriveApiKeysCryptoVersion,
      'kdf': kDriveApiKeysKdfId,
      'iterations': kDriveApiKeysPbkdf2Iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'ct': base64Encode(box.cipherText + box.mac.bytes),
    };
  }

  /// Decrypts a map produced by [encrypt]. MAC is last 16 bytes of decoded `ct`.
  static Future<List<int>> decrypt({
    required Map<String, dynamic> envelope,
    required String passphrase,
  }) async {
    final v = envelope['v'];
    if (v != kDriveApiKeysCryptoVersion) {
      throw DriveApiKeysDecryptException('unsupported format version: $v');
    }
    if (envelope['kdf'] != kDriveApiKeysKdfId) {
      throw DriveApiKeysDecryptException('unsupported KDF');
    }
    final iterations = envelope['iterations'];
    if (iterations != kDriveApiKeysPbkdf2Iterations) {
      throw DriveApiKeysDecryptException('unsupported KDF iterations');
    }

    final saltB64 = envelope['salt'] as String?;
    final nonceB64 = envelope['nonce'] as String?;
    final ctB64 = envelope['ct'] as String?;
    if (saltB64 == null || nonceB64 == null || ctB64 == null) {
      throw DriveApiKeysDecryptException('missing ciphertext fields');
    }

    List<int> b64Decode(String s) {
      try {
        return base64Decode(s);
      } catch (_) {
        throw DriveApiKeysDecryptException('invalid base64');
      }
    }

    final salt = b64Decode(saltB64);
    final nonce = b64Decode(nonceB64);
    final ctAndMac = b64Decode(ctB64);
    if (ctAndMac.length < 16) {
      throw DriveApiKeysDecryptException('ciphertext too short');
    }
    final cipherText = ctAndMac.sublist(0, ctAndMac.length - 16);
    final macBytes = ctAndMac.sublist(ctAndMac.length - 16);

    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );

    final box = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    try {
      return await _aes.decrypt(
        box,
        secretKey: secretKey,
      );
    } on SecretBoxAuthenticationError catch (_) {
      throw DriveApiKeysDecryptException(
        'wrong passphrase or corrupted data',
      );
    } catch (e) {
      throw DriveApiKeysDecryptException('decrypt failed: $e');
    }
  }

  /// Whether [json] matches the encrypted envelope format (v1).
  static bool isEncryptedEnvelope(Map<String, dynamic> json) {
    return json['v'] == kDriveApiKeysCryptoVersion &&
        json['ct'] is String &&
        json['salt'] is String &&
        json['nonce'] is String;
  }

  /// Whether [json] looks like legacy plaintext [SyncApiKeysData].
  static bool isLegacyPlaintextEnvelope(Map<String, dynamic> json) {
    if (isEncryptedEnvelope(json)) return false;
    return json.containsKey('lastModified') &&
        (json.containsKey('openaiApiKey') ||
            json.containsKey('mistralApiKey') ||
            json.containsKey('provider'));
  }
}
