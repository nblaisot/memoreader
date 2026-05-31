import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/codex_jwt.dart';

void main() {
  test('accountIdFromAccessToken reads chatgpt_account_id claim', () {
    final token = _fakeJwt({
      'exp': 2000000000,
      'https://api.openai.com/auth': {'chatgpt_account_id': 'acct_123'},
    });
    expect(CodexJwt.accountIdFromAccessToken(token), 'acct_123');
  });

  test('expiryFromAccessToken reads exp', () {
    const exp = 2000000000;
    final token = _fakeJwt({'exp': exp});
    expect(
      CodexJwt.expiryFromAccessToken(token)?.millisecondsSinceEpoch,
      exp * 1000,
    );
  });
}

String _fakeJwt(Map<String, dynamic> payload) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}')).replaceAll('=', '');
  final body =
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return '$header.$body.sig';
}
