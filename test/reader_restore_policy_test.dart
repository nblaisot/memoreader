import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/reading_progress.dart';
import 'package:memoreader/screens/reader/reader_restore_policy.dart';

void main() {
  ReadingProgress saved({
    int? contentVersion = 2,
    int start = 400,
    double percentage = 0.4,
  }) {
    return ReadingProgress(
      bookId: 'book',
      lastRead: DateTime.utc(2026),
      currentCharacterIndex: start,
      progress: percentage,
      contentVersion: contentVersion,
    );
  }

  test('uses exact character anchor for compatible content', () {
    expect(
      resolveRestoreTarget(
        progress: saved(),
        totalCharacters: 1000,
        currentContentVersion: 2,
      ),
      400,
    );
  });

  test('uses percentage when extraction version changed', () {
    expect(
      resolveRestoreTarget(
        progress: saved(contentVersion: 1),
        totalCharacters: 2000,
        currentContentVersion: 2,
      ),
      800,
    );
  });

  test('automatic zero is blocked after a successful restore', () {
    expect(
      shouldBlockAutomaticZero(
        userInitiated: false,
        reportedStartCharacter: 0,
        savedTarget: 400,
        restoreWasReady: true,
      ),
      isTrue,
    );
  });

  test('explicit user navigation to zero remains allowed', () {
    expect(
      shouldBlockAutomaticZero(
        userInitiated: true,
        reportedStartCharacter: 0,
        savedTarget: 400,
        restoreWasReady: true,
      ),
      isFalse,
    );
  });

  test('explicit beginning restores to character zero, not percentage', () {
    final progress = ReadingProgress(
      bookId: 'book',
      lastRead: DateTime.utc(2026),
      currentCharacterIndex: 0,
      progress: 0.01,
      contentVersion: 2,
      anchorOrigin: ReadingProgressAnchorOrigin.userNavigation,
    );

    expect(
      resolveRestoreTarget(
        progress: progress,
        totalCharacters: 10000,
        currentContentVersion: 2,
      ),
      0,
    );
  });
}
