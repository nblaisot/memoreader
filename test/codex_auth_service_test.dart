import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memoreader/services/codex_auth_constants.dart';
import 'package:memoreader/services/codex_auth_service.dart';

void main() {
  test('startDeviceCodeLogin returns session on success', () async {
    final client = MockClient((request) async {
      expect(request.url.path, contains('deviceauth/usercode'));
      return http.Response(
        jsonEncode({
          'device_auth_id': 'dev1',
          'user_code': 'ABCD-1234',
          'interval': '5',
        }),
        200,
      );
    });

    final auth = CodexAuthService(httpClient: client);
    final session = await auth.startDeviceCodeLogin();
    expect(session.userCode, 'ABCD-1234');
    expect(session.deviceAuthId, 'dev1');
    expect(session.verificationUrl, CodexAuthConstants.deviceVerificationUrl);
  });

  test('completeDeviceCodeLogin persists tokens', () async {
    String? storedJson;
    var pollCount = 0;

    final client = MockClient((request) async {
      if (request.url.path.endsWith('deviceauth/token')) {
        pollCount++;
        if (pollCount == 1) {
          return http.Response('', 403);
        }
        return http.Response(
          jsonEncode({
            'authorization_code': 'auth_code',
            'code_verifier': 'verifier',
            'code_challenge': 'challenge',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('oauth/token')) {
        return http.Response(
          jsonEncode({
            'access_token': _fakeJwt({'exp': 9999999999}),
            'refresh_token': 'refresh_xyz',
            'expires_in': 3600,
            'id_token': _fakeJwt({'email': 'user@test.com'}),
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final auth = CodexAuthService(
      httpClient: client,
      writeStoredJson: (v) async => storedJson = v,
      readStoredJson: () async => storedJson,
      deleteStoredJson: () async => storedJson = null,
    );

    await auth.completeDeviceCodeLogin(
      const CodexDeviceCodeSession(
        verificationUrl: CodexAuthConstants.deviceVerificationUrl,
        userCode: 'CODE',
        deviceAuthId: 'dev1',
        pollIntervalSeconds: 1,
      ),
    );

    expect(await auth.isConfigured(), isTrue);
    final creds = await auth.readCredentials();
    expect(creds?.refreshToken, 'refresh_xyz');
    expect(creds?.email, 'user@test.com');
  });

  test('refreshTokens updates stored access token', () async {
    String? stored = jsonEncode({
      'access_token': 'old_access',
      'refresh_token': 'refresh_xyz',
      'expires_at_ms': 0,
    });

    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'access_token': 'new_access',
          'refresh_token': 'refresh_new',
          'expires_in': 7200,
        }),
        200,
      ),
    );

    final auth = CodexAuthService(
      httpClient: client,
      readStoredJson: () async => stored,
      writeStoredJson: (v) async => stored = v,
      deleteStoredJson: () async => stored = null,
    );

    final updated = await auth.refreshTokens();
    expect(updated.accessToken, 'new_access');
    expect(updated.refreshToken, 'refresh_new');
  });
}

String _fakeJwt(Map<String, dynamic> payload) {
  final body = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return 'hdr.$body.sig';
}
