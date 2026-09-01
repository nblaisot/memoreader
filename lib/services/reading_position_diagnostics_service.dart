import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Small, private, release-build-safe event log for reading-position failures.
/// It deliberately excludes titles, text, account data, and credentials.
class ReadingPositionDiagnosticsService {
  ReadingPositionDiagnosticsService._();

  static final ReadingPositionDiagnosticsService _instance =
      ReadingPositionDiagnosticsService._();

  factory ReadingPositionDiagnosticsService() => _instance;

  static const int _maxBytes = 256 * 1024;
  Future<void> _tail = Future<void>.value();
  String? _appVersion;

  Future<void> record(
    String event, {
    required String bookId,
    String? sessionId,
    Map<String, Object?> details = const {},
  }) {
    final safeBookId = bookId.length <= 12 ? bookId : bookId.substring(0, 12);
    final operation = _tail.then((_) async {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final diagnosticsDirectory = Directory(
          p.join(directory.path, 'diagnostics'),
        );
        await diagnosticsDirectory.create(recursive: true);
        final file = File(
          p.join(diagnosticsDirectory.path, 'reading-position.jsonl'),
        );
        final backup = File('${file.path}.1');
        if (await file.exists() && await file.length() >= _maxBytes) {
          if (await backup.exists()) await backup.delete();
          await file.rename(backup.path);
        }
        _appVersion ??= await _resolveAppVersion();
        final payload = <String, Object?>{
          'timestampUtc': DateTime.now().toUtc().toIso8601String(),
          'appVersion': _appVersion,
          'event': event,
          'bookId': safeBookId,
          if (sessionId != null) 'sessionId': sessionId,
          ...details,
        };
        await file.writeAsString(
          '${jsonEncode(payload)}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // Diagnostics must never interfere with reading or progress persistence.
      }
    });
    _tail = operation.catchError((_) {});
    return operation;
  }

  Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }
}
