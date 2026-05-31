import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/resolving_http_client.dart';

void main() {
  test(
    'resolveHostViaGoogleDoh returns IPv4 for chatgpt.com',
    () async {
      final address = await resolveHostViaGoogleDoh('chatgpt.com');
      expect(address.type, InternetAddressType.IPv4);
      expect(address.address, isNotEmpty);
    },
    skip: !Platform.isMacOS && !Platform.isLinux && !Platform.isWindows,
  );

  test(
    'parseGoogleDoh-style response rejects empty answers',
    () async {
      expect(
        () => resolveHostViaGoogleDoh(
          'this-host-should-not-exist-xyz123.invalid',
        ),
        throwsA(isA<SocketException>()),
      );
    },
    skip: !Platform.isMacOS && !Platform.isLinux && !Platform.isWindows,
  );
}
