import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Google Public DNS over HTTPS (connect via IP so bootstrap needs no system DNS).
const _googleDohIp = '8.8.8.8';
const _googleDohHost = 'dns.google';

/// Resolves [hostname] to an IPv4 address using Google Public DNS over HTTPS.
@visibleForTesting
Future<InternetAddress> resolveHostViaGoogleDoh(String hostname) async {
  final bootstrap = HttpClient();
  try {
    final request = await bootstrap.getUrl(
      Uri.parse(
        'https://$_googleDohIp/resolve?name=${Uri.encodeQueryComponent(hostname)}&type=1',
      ),
    );
    request.headers.set(HttpHeaders.hostHeader, _googleDohHost);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw SocketException(
        'DNS lookup failed for $hostname (DoH HTTP ${response.statusCode})',
      );
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final answers = json['Answer'] as List<dynamic>?;
    if (answers != null) {
      for (final entry in answers) {
        if (entry is! Map<String, dynamic>) continue;
        if (entry['type'] != 1) continue;
        final data = entry['data'] as String?;
        if (data != null && data.isNotEmpty) {
          return InternetAddress(data);
        }
      }
    }
    throw SocketException('DNS lookup failed for $hostname (no IPv4 in DoH)');
  } finally {
    bootstrap.close(force: true);
  }
}

/// HTTP client that falls back to DNS-over-HTTPS when system DNS fails.
///
/// Some Android emulators ship with broken DNS (IP connectivity works but
/// hostname resolution fails). Codex/OpenAI calls then fail with
/// "Failed host lookup". This client resolves via Google Public DNS (8.8.8.8)
/// when [InternetAddress.lookup] fails.
http.Client createResolvingHttpClient() {
  final ioHttp = HttpClient();
  ioHttp.findProxy = (_) => 'DIRECT';
  ioHttp
      .connectionFactory = (Uri url, String? proxyHost, int? proxyPort) async {
    InternetAddress address;
    try {
      final results = await InternetAddress.lookup(
        url.host,
        type: InternetAddressType.IPv4,
      );
      if (results.isEmpty) {
        throw const SocketException('No IPv4 address');
      }
      address = results.first;
    } on SocketException {
      address = await resolveHostViaGoogleDoh(url.host);
      if (kDebugMode) {
        debugPrint('[Network] DoH resolved ${url.host} -> ${address.address}');
      }
    }

    final port =
        proxyPort ??
        (url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80));
    final socket = Socket.connect(address, port).then<Socket>((socket) {
      if (url.scheme != 'https') return socket;
      return SecureSocket.secure(socket, host: url.host);
    });
    return ConnectionTask.fromSocket(socket, () {});
  };

  return IOClient(ioHttp);
}
