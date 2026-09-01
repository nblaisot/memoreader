import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/google_drive_sync_service.dart';
import 'package:memoreader/widgets/compact_error_snack_bar.dart';

void main() {
  test('only sync errors request a global notification', () {
    expect(
      shouldNotifyForSyncState(const SyncState(SyncStatus.syncing)),
      isFalse,
    );
    expect(
      shouldNotifyForSyncState(const SyncState(SyncStatus.success)),
      isFalse,
    );
    expect(shouldNotifyForSyncState(const SyncState(SyncStatus.idle)), isFalse);
    expect(shouldNotifyForSyncState(const SyncState(SyncStatus.error)), isTrue);
  });

  test('partial sync failure is not success', () {
    const result = SyncResult(SyncOutcome.partialFailure, message: 'partial');
    expect(result.failed, isTrue);
    expect(result.succeeded, isFalse);
  });

  test('error snackbar uses compact floating presentation', () {
    final snackBar = compactErrorSnackBar('failure');
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(snackBar.duration, const Duration(seconds: 4));
    expect(
      snackBar.padding,
      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
    expect(snackBar.margin, const EdgeInsets.fromLTRB(16, 0, 16, 12));
  });
}
