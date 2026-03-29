import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/drive_api_keys_cipher.dart';

void main() {
  group('DriveApiKeysCipher', () {
    // -------------------------------------------------------------------------
    // Happy-path tests
    // -------------------------------------------------------------------------

    test('roundtrip encrypt/decrypt', () async {
      const passphrase = 'correct horse battery staple';
      final plain = utf8.encode('{"openaiApiKey":"sk-test","lastModified":"2020-01-01T00:00:00.000Z"}');

      final env = await DriveApiKeysCipher.encrypt(
        plaintextUtf8: plain,
        passphrase: passphrase,
      );

      expect(env['v'], kDriveApiKeysCryptoVersion);
      expect(env['kdf'], kDriveApiKeysKdfId);
      expect(DriveApiKeysCipher.isEncryptedEnvelope(Map<String, dynamic>.from(env)), isTrue);

      final out = await DriveApiKeysCipher.decrypt(
        envelope: Map<String, dynamic>.from(env),
        passphrase: passphrase,
      );
      expect(out, plain);
    });

    test('roundtrip with empty plaintext', () async {
      final plain = utf8.encode('');
      final env = await DriveApiKeysCipher.encrypt(
        plaintextUtf8: plain,
        passphrase: 'my-passphrase',
      );
      final out = await DriveApiKeysCipher.decrypt(
        envelope: Map<String, dynamic>.from(env),
        passphrase: 'my-passphrase',
      );
      expect(out, plain);
    });

    test('wrong passphrase fails', () async {
      final plain = utf8.encode('{}');
      final env = await DriveApiKeysCipher.encrypt(
        plaintextUtf8: plain,
        passphrase: 'one',
      );

      expect(
        () => DriveApiKeysCipher.decrypt(
          envelope: Map<String, dynamic>.from(env),
          passphrase: 'two',
        ),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    test('tampered ciphertext fails', () async {
      final plain = utf8.encode('secret');
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: plain,
          passphrase: 'p',
        ),
      );
      final ct = base64Decode(env['ct'] as String);
      ct[0] = ct[0] ^ 0xff;
      env['ct'] = base64Encode(ct);

      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    // -------------------------------------------------------------------------
    // Malformed / missing envelope fields
    // -------------------------------------------------------------------------

    test('missing salt field throws DriveApiKeysDecryptException', () async {
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: utf8.encode('data'),
          passphrase: 'p',
        ),
      );
      env.remove('salt');
      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    test('missing nonce field throws DriveApiKeysDecryptException', () async {
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: utf8.encode('data'),
          passphrase: 'p',
        ),
      );
      env.remove('nonce');
      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    test('missing ct field throws DriveApiKeysDecryptException', () async {
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: utf8.encode('data'),
          passphrase: 'p',
        ),
      );
      env.remove('ct');
      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    test('invalid base64 in salt throws DriveApiKeysDecryptException', () async {
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: utf8.encode('data'),
          passphrase: 'p',
        ),
      );
      env['salt'] = '!!! not base64 !!!';
      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    test('invalid base64 in ct throws DriveApiKeysDecryptException', () async {
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: utf8.encode('data'),
          passphrase: 'p',
        ),
      );
      env['ct'] = '!!! not base64 !!!';
      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    test('wrong version number throws DriveApiKeysDecryptException', () async {
      final env = Map<String, dynamic>.from(
        await DriveApiKeysCipher.encrypt(
          plaintextUtf8: utf8.encode('data'),
          passphrase: 'p',
        ),
      );
      env['v'] = 999;
      expect(
        () => DriveApiKeysCipher.decrypt(envelope: env, passphrase: 'p'),
        throwsA(isA<DriveApiKeysDecryptException>()),
      );
    });

    // -------------------------------------------------------------------------
    // Envelope detection helpers
    // -------------------------------------------------------------------------

    test('legacy vs encrypted detection', () {
      expect(
        DriveApiKeysCipher.isLegacyPlaintextEnvelope({
          'lastModified': '2020-01-01T00:00:00.000Z',
          'openaiApiKey': 'x',
        }),
        isTrue,
      );
      expect(
        DriveApiKeysCipher.isEncryptedEnvelope({
          'v': kDriveApiKeysCryptoVersion,
          'kdf': kDriveApiKeysKdfId,
          'iterations': kDriveApiKeysPbkdf2Iterations,
          'salt': 'AAAA',
          'nonce': 'AAAA',
          'ct': 'AAAA',
        }),
        isTrue,
      );
    });

    test('isEncryptedEnvelope returns false when version is wrong', () {
      expect(
        DriveApiKeysCipher.isEncryptedEnvelope({
          'v': 999,
          'ct': 'AAAA',
          'salt': 'AAAA',
          'nonce': 'AAAA',
        }),
        isFalse,
      );
    });

    test('isEncryptedEnvelope returns false when ct is missing', () {
      expect(
        DriveApiKeysCipher.isEncryptedEnvelope({
          'v': kDriveApiKeysCryptoVersion,
          'salt': 'AAAA',
          'nonce': 'AAAA',
        }),
        isFalse,
      );
    });

    test('isLegacyPlaintextEnvelope returns false for encrypted envelope', () async {
      final env = await DriveApiKeysCipher.encrypt(
        plaintextUtf8: utf8.encode('{}'),
        passphrase: 'p',
      );
      expect(
        DriveApiKeysCipher.isLegacyPlaintextEnvelope(Map<String, dynamic>.from(env)),
        isFalse,
      );
    });

    test('isLegacyPlaintextEnvelope returns false when no API key fields present', () {
      expect(
        DriveApiKeysCipher.isLegacyPlaintextEnvelope({
          'lastModified': '2020-01-01T00:00:00.000Z',
          'unrelated': 'field',
        }),
        isFalse,
      );
    });

    test('isLegacyPlaintextEnvelope returns true with mistralApiKey only', () {
      expect(
        DriveApiKeysCipher.isLegacyPlaintextEnvelope({
          'lastModified': '2020-01-01T00:00:00.000Z',
          'mistralApiKey': 'mk-xxx',
        }),
        isTrue,
      );
    });

    test('isLegacyPlaintextEnvelope returns true with provider only', () {
      expect(
        DriveApiKeysCipher.isLegacyPlaintextEnvelope({
          'lastModified': '2020-01-01T00:00:00.000Z',
          'provider': 'openai',
        }),
        isTrue,
      );
    });
  });
}
