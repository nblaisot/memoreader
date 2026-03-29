import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/book.dart';
import 'package:memoreader/services/drive_sync_merge.dart';

void main() {
  Book book(String id, DateTime added) {
    return Book(
      id: id,
      title: 'T',
      author: 'A',
      filePath: '/$id.epub',
      dateAdded: added,
    );
  }

  // ---------------------------------------------------------------------------
  // mergeBookAndDeletionTimestamps — existing tests
  // ---------------------------------------------------------------------------

  test('prefers remote book when newer than local', () {
    final local = book('1', DateTime.utc(2020, 1, 1));
    final remote = book('1', DateTime.utc(2021, 1, 1));
    final r = mergeBookAndDeletionTimestamps(
      localBook: local,
      remoteBook: remote,
      localDeletion: null,
      remoteDeletion: null,
    );
    expect(r.newestBook, remote);
  });

  test('deletion wins when newer than book dateAdded', () {
    final b = book('1', DateTime.utc(2020, 1, 1));
    final deleted = DateTime.utc(2021, 1, 1);
    final r = mergeBookAndDeletionTimestamps(
      localBook: b,
      remoteBook: null,
      localDeletion: deleted,
      remoteDeletion: null,
    );
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isFalse);
  });

  test('book wins when dateAdded after deletion', () {
    final b = book('1', DateTime.utc(2022, 1, 1));
    final deleted = DateTime.utc(2021, 1, 1);
    final r = mergeBookAndDeletionTimestamps(
      localBook: b,
      remoteBook: null,
      localDeletion: deleted,
      remoteDeletion: null,
    );
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isTrue);
  });

  test('picks latest deletion from local vs remote', () {
    final b = book('1', DateTime.utc(2023, 1, 1));
    final r = mergeBookAndDeletionTimestamps(
      localBook: b,
      remoteBook: null,
      localDeletion: DateTime.utc(2022, 1, 1),
      remoteDeletion: DateTime.utc(2024, 1, 1),
    );
    expect(r.newestDeletion, DateTime.utc(2024, 1, 1));
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isFalse);
  });

  // ---------------------------------------------------------------------------
  // mergeBookAndDeletionTimestamps — edge cases
  // ---------------------------------------------------------------------------

  test('both local and remote present: prefers local when local is newer', () {
    final local = book('1', DateTime.utc(2022, 6, 1));
    final remote = book('1', DateTime.utc(2021, 1, 1));
    final r = mergeBookAndDeletionTimestamps(
      localBook: local,
      remoteBook: remote,
      localDeletion: null,
      remoteDeletion: null,
    );
    expect(r.newestBook, local);
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isTrue);
  });

  test('both local and remote present with equal timestamps: keeps local', () {
    final ts = DateTime.utc(2023, 1, 1);
    final local = book('1', ts);
    final remote = book('1', ts);
    final r = mergeBookAndDeletionTimestamps(
      localBook: local,
      remoteBook: remote,
      localDeletion: null,
      remoteDeletion: null,
    );
    // isAfter is false for equal, so localBook is returned
    expect(r.newestBook, local);
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isTrue);
  });

  test('no book and no deletion on either side: should not exist', () {
    final r = mergeBookAndDeletionTimestamps(
      localBook: null,
      remoteBook: null,
      localDeletion: null,
      remoteDeletion: null,
    );
    expect(r.newestBook, isNull);
    expect(r.newestDeletion, isNull);
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isFalse);
  });

  test('only remote book (no local, no deletion): should exist', () {
    final remote = book('2', DateTime.utc(2024, 3, 15));
    final r = mergeBookAndDeletionTimestamps(
      localBook: null,
      remoteBook: remote,
      localDeletion: null,
      remoteDeletion: null,
    );
    expect(r.newestBook, remote);
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isTrue);
  });

  test('only local book (no remote, no deletion): should exist', () {
    final local = book('3', DateTime.utc(2024, 1, 10));
    final r = mergeBookAndDeletionTimestamps(
      localBook: local,
      remoteBook: null,
      localDeletion: null,
      remoteDeletion: null,
    );
    expect(r.newestBook, local);
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isTrue);
  });

  test('deletion at exact same time as dateAdded: deletion wins (not strictly after)', () {
    final ts = DateTime.utc(2023, 6, 1);
    final b = book('4', ts);
    final r = mergeBookAndDeletionTimestamps(
      localBook: b,
      remoteBook: null,
      localDeletion: ts,
      remoteDeletion: null,
    );
    // dateAdded.isAfter(deletion) is false when equal → deleted
    expect(bookShouldExistAfterMerge(r.newestBook, r.newestDeletion), isFalse);
  });

  test('local deletion only: newestDeletion is local', () {
    final del = DateTime.utc(2024, 5, 1);
    final r = mergeBookAndDeletionTimestamps(
      localBook: null,
      remoteBook: null,
      localDeletion: del,
      remoteDeletion: null,
    );
    expect(r.newestDeletion, del);
  });

  test('remote deletion only: newestDeletion is remote', () {
    final del = DateTime.utc(2024, 7, 1);
    final r = mergeBookAndDeletionTimestamps(
      localBook: null,
      remoteBook: null,
      localDeletion: null,
      remoteDeletion: del,
    );
    expect(r.newestDeletion, del);
  });

  test('equal local and remote deletions: picks either (not-after → remote)', () {
    final ts = DateTime.utc(2024, 1, 1);
    final r = mergeBookAndDeletionTimestamps(
      localBook: null,
      remoteBook: null,
      localDeletion: ts,
      remoteDeletion: ts,
    );
    // localDeletion.isAfter(remoteDeletion) == false → remoteDeletion returned
    expect(r.newestDeletion, ts);
  });
}
