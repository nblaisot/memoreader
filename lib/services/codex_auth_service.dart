import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'codex_auth_constants.dart';
import 'codex_jwt.dart';
import 'resolving_http_client.dart';

/// Thrown when Codex OAuth login or refresh fails.
class CodexAuthException implements Exception {
  CodexAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Device-code login session shown in settings UI.
class CodexDeviceCodeSession {
  const CodexDeviceCodeSession({
    required this.verificationUrl,
    required this.userCode,
    required this.deviceAuthId,
    required this.pollIntervalSeconds,
  });

  final String verificationUrl;
  final String userCode;
  final String deviceAuthId;
  final int pollIntervalSeconds;
}

/// Persisted ChatGPT/Codex OAuth credentials.
class CodexAuthCredentials {
  const CodexAuthCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.accountId,
    this.email,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String? accountId;
  final String? email;

  bool get isExpired => DateTime.now().toUtc().isAfter(
    expiresAt.subtract(CodexAuthConstants.refreshSkew),
  );
}

/// ChatGPT/Codex subscription OAuth (device code flow) with secure storage.
class CodexAuthService {
  CodexAuthService({
    http.Client? httpClient,
    Future<String?> Function()? readStoredJson,
    Future<void> Function(String value)? writeStoredJson,
    Future<void> Function()? deleteStoredJson,
  }) : _http = httpClient ?? createResolvingHttpClient(),
       _readStoredJson = readStoredJson,
       _writeStoredJson = writeStoredJson,
       _deleteStoredJson = deleteStoredJson;

  static const _storageKey = 'codex_chatgpt_oauth_tokens';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  final http.Client _http;
  final Future<String?> Function()? _readStoredJson;
  final Future<void> Function(String value)? _writeStoredJson;
  final Future<void> Function()? _deleteStoredJson;

  Future<CodexDeviceCodeSession> startDeviceCodeLogin() async {
    final url = Uri.parse(
      '${CodexAuthConstants.accountsApiBase}/deviceauth/usercode',
    );
    final response = await _http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'client_id': CodexAuthConstants.clientId}),
    );

    if (response.statusCode == 404) {
      throw CodexAuthException(
        'Device code login is not enabled for your ChatGPT account. '
        'Enable it in ChatGPT security settings (Plus/Pro), or use an API key provider.',
      );
    }
    if (!response.statusCode.toString().startsWith('2')) {
      throw CodexAuthException(
        'Could not start ChatGPT login (${response.statusCode}).',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final deviceAuthId = data['device_auth_id'] as String?;
    final userCode = (data['user_code'] ?? data['usercode']) as String?;
    if (deviceAuthId == null || userCode == null) {
      throw CodexAuthException('Invalid device code response from OpenAI.');
    }

    final intervalRaw = data['interval'];
    final interval = intervalRaw is int
        ? intervalRaw
        : int.tryParse(intervalRaw?.toString() ?? '') ?? 5;

    return CodexDeviceCodeSession(
      verificationUrl: CodexAuthConstants.deviceVerificationUrl,
      userCode: userCode,
      deviceAuthId: deviceAuthId,
      pollIntervalSeconds: interval.clamp(2, 30),
    );
  }

  /// Polls until the user completes browser login or [timeout] elapses.
  Future<void> completeDeviceCodeLogin(
    CodexDeviceCodeSession session, {
    Duration timeout = CodexAuthConstants.deviceLoginTimeout,
  }) async {
    final pollUrl = Uri.parse(
      '${CodexAuthConstants.accountsApiBase}/deviceauth/token',
    );
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final pollResponse = await _http.post(
        pollUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_auth_id': session.deviceAuthId,
          'user_code': session.userCode,
        }),
      );

      if (pollResponse.statusCode == 200) {
        final pollData = jsonDecode(pollResponse.body) as Map<String, dynamic>;
        final authCode = pollData['authorization_code'] as String?;
        final codeVerifier = pollData['code_verifier'] as String?;
        if (authCode == null || codeVerifier == null) {
          throw CodexAuthException('Device login response incomplete.');
        }
        await _exchangeAuthorizationCode(
          code: authCode,
          codeVerifier: codeVerifier,
        );
        return;
      }

      if (pollResponse.statusCode == 403 || pollResponse.statusCode == 404) {
        await Future<void>.delayed(
          Duration(seconds: session.pollIntervalSeconds),
        );
        continue;
      }

      throw CodexAuthException(
        'Device login failed (${pollResponse.statusCode}).',
      );
    }

    throw CodexAuthException(
      'ChatGPT sign-in timed out. Open the link, enter the code, and try again.',
    );
  }

  Future<void> _exchangeAuthorizationCode({
    required String code,
    required String codeVerifier,
  }) async {
    final response = await _http.post(
      Uri.parse(CodexAuthConstants.tokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': CodexAuthConstants.clientId,
        'code': code,
        'code_verifier': codeVerifier,
        'redirect_uri': CodexAuthConstants.deviceRedirectUri,
      },
    );

    if (!response.statusCode.toString().startsWith('2')) {
      if (kDebugMode) {
        debugPrint('[CodexAuth] code exchange failed: ${response.body}');
      }
      throw CodexAuthException('Could not complete ChatGPT sign-in.');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    await _persistTokenResponse(json);
  }

  Future<void> _persistTokenResponse(Map<String, dynamic> json) async {
    final access = json['access_token'] as String?;
    final refresh = json['refresh_token'] as String?;
    final expiresIn = json['expires_in'];
    final idToken = json['id_token'] as String?;

    if (access == null || refresh == null) {
      throw CodexAuthException('Token response missing required fields.');
    }

    final expiresSeconds = expiresIn is int
        ? expiresIn
        : int.tryParse(expiresIn?.toString() ?? '') ?? 3600;
    final expiresAt = DateTime.now().toUtc().add(
      Duration(seconds: expiresSeconds),
    );

    final accountId = CodexJwt.accountIdFromAccessToken(access);
    final email = CodexJwt.emailFromIdToken(idToken);

    await _writeCredentials(
      CodexAuthCredentials(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiresAt,
        accountId: accountId,
        email: email,
      ),
    );
  }

  Future<bool> isConfigured() async {
    final creds = await readCredentials();
    return creds != null && creds.refreshToken.isNotEmpty;
  }

  Future<String?> _readRaw() async {
    if (_readStoredJson != null) {
      return _readStoredJson!();
    }
    return _secureStorage.read(key: _storageKey);
  }

  Future<void> _writeRaw(String value) async {
    if (_writeStoredJson != null) {
      await _writeStoredJson!(value);
      return;
    }
    await _secureStorage.write(key: _storageKey, value: value);
  }

  Future<void> _deleteRaw() async {
    if (_deleteStoredJson != null) {
      await _deleteStoredJson!();
      return;
    }
    await _secureStorage.delete(key: _storageKey);
  }

  Future<CodexAuthCredentials?> readCredentials() async {
    final raw = await _readRaw();
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final access = map['access_token'] as String?;
      final refresh = map['refresh_token'] as String?;
      final expiresMs = map['expires_at_ms'];
      if (access == null || refresh == null || expiresMs == null) {
        return null;
      }
      return CodexAuthCredentials(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          expiresMs as int,
          isUtc: true,
        ),
        accountId: map['account_id'] as String?,
        email: map['email'] as String?,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CodexAuth] Failed to parse stored credentials: $e');
      }
      return null;
    }
  }

  Future<void> _writeCredentials(CodexAuthCredentials credentials) async {
    await _writeRaw(
      jsonEncode({
        'access_token': credentials.accessToken,
        'refresh_token': credentials.refreshToken,
        'expires_at_ms': credentials.expiresAt.millisecondsSinceEpoch,
        if (credentials.accountId != null) 'account_id': credentials.accountId,
        if (credentials.email != null) 'email': credentials.email,
      }),
    );
  }

  /// Returns a valid access token, refreshing when near expiry.
  Future<CodexAuthCredentials> getValidCredentials() async {
    final creds = await readCredentials();
    if (creds == null) {
      throw CodexAuthException(
        'ChatGPT is not signed in. Sign in from Settings.',
      );
    }
    if (!creds.isExpired) {
      return creds;
    }
    return refreshTokens(creds);
  }

  Future<CodexAuthCredentials> refreshTokens([
    CodexAuthCredentials? existing,
  ]) async {
    final creds = existing ?? await readCredentials();
    if (creds == null) {
      throw CodexAuthException('No ChatGPT session to refresh.');
    }

    final response = await _http.post(
      Uri.parse(CodexAuthConstants.tokenUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'client_id': CodexAuthConstants.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': creds.refreshToken,
      }),
    );

    if (!response.statusCode.toString().startsWith('2')) {
      if (response.statusCode == 401 || response.statusCode == 400) {
        await logout();
        throw CodexAuthException(
          'ChatGPT session expired. Please sign in again.',
        );
      }
      throw CodexAuthException(
        'Could not refresh ChatGPT session (${response.statusCode}).',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    await _persistTokenResponse(json);
    final updated = await readCredentials();
    if (updated == null) {
      throw CodexAuthException('Failed to store refreshed tokens.');
    }
    return updated;
  }

  Future<void> logout() async {
    await _deleteRaw();
  }
}
