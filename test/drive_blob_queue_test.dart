import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/services/google_drive_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the pending Drive blob delete queue logic in
/// [GoogleDriveSyncService].
///
/// These tests exercise only the public queue API ([onBookDeleted],
/// [onBookReAdded], [clearPendingDriveBlobDeletes]) without requiring an
/// authenticated Google session.  The queue state is verified by reading
/// SharedPreferences directly with the known storage key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The SharedPreferences key used by GoogleDriveSyncService internally.
  const pendingBlobKey = 'google_drive_pending_blob_deletes';

  late GoogleDriveSyncService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Always the singleton — reset is handled by clearing prefs in setUp.
    service = GoogleDriveSyncService();
  });

  Future<List<String>> readQueue() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(pendingBlobKey) ?? [];
  }

  group('Drive blob delete queue', () {
    test('onBookDeleted enqueues the book ID', () async {
      await service.onBookDeleted('book-1');
      expect(await readQueue(), contains('book-1'));
    });

    test('onBookDeleted enqueues multiple books', () async {
      await service.onBookDeleted('book-a');
      await service.onBookDeleted('book-b');
      final q = await readQueue();
      expect(q, containsAll(['book-a', 'book-b']));
    });

    test('onBookDeleted does not enqueue the same book twice', () async {
      await service.onBookDeleted('book-dup');
      await service.onBookDeleted('book-dup');
      final q = await readQueue();
      expect(q.where((id) => id == 'book-dup').length, 1);
    });

    test('onBookDeleted returns false when not authenticated', () async {
      final result = await service.onBookDeleted('book-offline');
      expect(result, isFalse);
    });

    test('onBookReAdded removes book from the queue', () async {
      await service.onBookDeleted('book-readd');
      expect(await readQueue(), contains('book-readd'));

      await service.onBookReAdded('book-readd');
      expect(await readQueue(), isNot(contains('book-readd')));
    });

    test('onBookReAdded on a non-queued book is a no-op', () async {
      await service.onBookDeleted('book-x');
      await service.onBookReAdded('book-y'); // 'y' was never queued
      expect(await readQueue(), contains('book-x'));
      expect(await readQueue(), isNot(contains('book-y')));
    });

    test('onBookReAdded clears the deletion tombstone', () async {
      await service.onBookDeleted('book-tombstone');
      await service.onBookReAdded('book-tombstone');
      // After re-add, deletion tombstone should also be cleared.
      // We verify indirectly: onBookDeleted after onBookReAdded re-enqueues,
      // meaning the tombstone is not being held.
      await service.onBookDeleted('book-tombstone');
      expect(await readQueue(), contains('book-tombstone'));
    });

    test('clearPendingDriveBlobDeletes empties the queue', () async {
      await service.onBookDeleted('book-1');
      await service.onBookDeleted('book-2');
      expect((await readQueue()).length, greaterThanOrEqualTo(2));

      await service.clearPendingDriveBlobDeletes();
      expect(await readQueue(), isEmpty);
    });

    test('processPendingDriveBlobDeletes is a no-op when not authenticated', () async {
      await service.onBookDeleted('book-noop');
      // Not authenticated, so the queue should not change
      await service.processPendingDriveBlobDeletes();
      expect(await readQueue(), contains('book-noop'));
    });
  });
}
