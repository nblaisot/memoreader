import 'dart:convert';

import 'codex_auth_constants.dart';

/// Helpers for Codex OAuth JWT access tokens.
class CodexJwt {
  CodexJwt._();

  static Map<String, dynamic>? decodePayload(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      var payload = parts[1];
      final mod = payload.length % 4;
      if (mod > 0) {
        payload += '=' * (4 - mod);
      }
      final decoded = utf8.decode(base64Url.decode(payload));
      return jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static DateTime? expiryFromAccessToken(String accessToken) {
    final payload = decodePayload(accessToken);
    final exp = payload?['exp'];
    if (exp is int) {
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    }
    return null;
  }

  static String? accountIdFromAccessToken(String accessToken) {
    final payload = decodePayload(accessToken);
    if (payload == null) return null;
    final auth = payload[CodexAuthConstants.jwtAuthClaimPath];
    if (auth is Map<String, dynamic>) {
      final id = auth['chatgpt_account_id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  static String? emailFromIdToken(String? idToken) {
    if (idToken == null || idToken.isEmpty) return null;
    final payload = decodePayload(idToken);
    final email = payload?['email'];
    if (email is String && email.isNotEmpty) return email;
    return null;
  }
}
