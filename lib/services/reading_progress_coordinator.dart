import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_progress.dart';
import 'reading_position_diagnostics_service.dart';

enum ProgressWriteOutcome { saved, keptLocal, failed }

class ProgressWriteResult {
  const ProgressWriteResult(this.outcome, this.progress, {this.error});

  final ProgressWriteOutcome outcome;
  final ReadingProgress? progress;
  final Object? error;

  bool get succeeded => outcome != ProgressWriteOutcome.failed;
}

/// Determines which confirmed position is authoritative.
ReadingProgress chooseReadingProgress({
  required ReadingProgress local,
  required ReadingProgress remote,
}) {
  final remoteIsUnconfirmedBeginning =
      remote.isAtBeginning &&
      remote.anchorOrigin != ReadingProgressAnchorOrigin.userNavigation;
  if (!local.isAtBeginning && remoteIsUnconfirmedBeginning) return local;
  return remote.lastRead.isAfter(local.lastRead) ? remote : local;
}

/// Serializes every progress operation per book so stale async writes cannot
/// complete after newer writes. Drive and reader code share this singleton.
class ReadingProgressCoordinator {
  ReadingProgressCoordinator._();

  static final ReadingProgressCoordinator _instance =
      ReadingProgressCoordinator._();

  factory ReadingProgressCoordinator() => _instance;

  static const String _progressKey = 'reading_progress_';
  final Map<String, Future<void>> _tails = {};
  final StreamController<ReadingProgress> _updates =
      StreamController<ReadingProgress>.broadcast();
  final ReadingPositionDiagnosticsService _diagnostics =
      ReadingPositionDiagnosticsService();

  Stream<ReadingProgress> get updates => _updates.stream;

  Future<ReadingProgress?> read(String bookId) async {
    if (bookId.isEmpty) return null;
    await flush(bookId);
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString('$_progressKey$bookId');
      if (encoded == null) return null;
      return ReadingProgress.fromJson(jsonDecode(encoded));
    } catch (error) {
      unawaited(
        _diagnostics.record(
          'progress_read_failed',
          bookId: bookId,
          details: {'errorType': error.runtimeType.toString()},
        ),
      );
      return null;
    }
  }

  Future<ProgressWriteResult> save(
    ReadingProgress progress, {
    String reason = 'unspecified',
    String? sessionId,
  }) {
    return _enqueue(progress.bookId, () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final existing = _decode(
          prefs.getString('$_progressKey${progress.bookId}'),
        );
        if (existing != null && existing.lastRead.isAfter(progress.lastRead)) {
          await _logDecision(
            'progress_save_skipped_stale',
            progress.bookId,
            existing,
            reason: reason,
            sessionId: sessionId,
          );
          return ProgressWriteResult(ProgressWriteOutcome.keptLocal, existing);
        }
        final ok = await prefs.setString(
          '$_progressKey${progress.bookId}',
          jsonEncode(progress.toJson()),
        );
        if (!ok) throw StateError('SharedPreferences rejected progress write');
        _updates.add(progress);
        await _logDecision(
          'progress_saved',
          progress.bookId,
          progress,
          reason: reason,
          sessionId: sessionId,
        );
        return ProgressWriteResult(ProgressWriteOutcome.saved, progress);
      } catch (error) {
        debugPrint('Failed to save reading progress: $error');
        unawaited(
          _diagnostics.record(
            'progress_save_failed',
            bookId: progress.bookId,
            sessionId: sessionId,
            details: {
              'reason': reason,
              'errorType': error.runtimeType.toString(),
            },
          ),
        );
        return ProgressWriteResult(
          ProgressWriteOutcome.failed,
          null,
          error: error,
        );
      }
    });
  }

  Future<ProgressWriteResult> mergeRemote(ReadingProgress remote) {
    return _enqueue(remote.bookId, () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final local = _decode(prefs.getString('$_progressKey${remote.bookId}'));
        if (local != null) {
          final chosen = chooseReadingProgress(local: local, remote: remote);
          if (identical(chosen, local)) {
            await _logDecision(
              'sync_progress_kept_local',
              remote.bookId,
              local,
              reason: remote.isAtBeginning
                  ? 'protected_from_unconfirmed_zero'
                  : 'local_is_newer_or_equal',
            );
            return ProgressWriteResult(ProgressWriteOutcome.keptLocal, local);
          }
        }
        final ok = await prefs.setString(
          '$_progressKey${remote.bookId}',
          jsonEncode(remote.toJson()),
        );
        if (!ok) throw StateError('SharedPreferences rejected remote progress');
        _updates.add(remote);
        await _logDecision(
          'sync_progress_applied_remote',
          remote.bookId,
          remote,
          reason: 'remote_is_newer',
        );
        return ProgressWriteResult(ProgressWriteOutcome.saved, remote);
      } catch (error) {
        unawaited(
          _diagnostics.record(
            'sync_progress_merge_failed',
            bookId: remote.bookId,
            details: {'errorType': error.runtimeType.toString()},
          ),
        );
        return ProgressWriteResult(
          ProgressWriteOutcome.failed,
          null,
          error: error,
        );
      }
    });
  }

  Future<void> flush(String bookId) => _tails[bookId] ?? Future<void>.value();

  Future<T> _enqueue<T>(String bookId, Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _tails[bookId] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    late final Future<void> tracked;
    tracked = next.whenComplete(() {
      if (identical(_tails[bookId], tracked)) _tails.remove(bookId);
    });
    _tails[bookId] = tracked;
    return completer.future;
  }

  ReadingProgress? _decode(String? encoded) {
    if (encoded == null) return null;
    try {
      return ReadingProgress.fromJson(jsonDecode(encoded));
    } catch (_) {
      return null;
    }
  }

  Future<void> _logDecision(
    String event,
    String bookId,
    ReadingProgress progress, {
    required String reason,
    String? sessionId,
  }) {
    return _diagnostics.record(
      event,
      bookId: bookId,
      sessionId: sessionId,
      details: {
        'reason': reason,
        'lastReadUtc': progress.lastRead.toUtc().toIso8601String(),
        'startChar': progress.currentCharacterIndex,
        'endChar': progress.lastVisibleCharacterIndex,
        'pageIndex': progress.currentPageIndex,
        'progress': progress.progress,
        'totalCharacters': progress.totalCharacters,
        'contentVersion': progress.contentVersion,
        'anchorOrigin': progress.anchorOrigin.name,
        'layoutKey': progress.layoutKey,
      },
    );
  }
}
