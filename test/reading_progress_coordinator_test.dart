import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/models/reading_progress.dart';
import 'package:memoreader/services/reading_progress_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReadingProgress progress({
  required DateTime at,
  required int start,
  ReadingProgressAnchorOrigin origin = ReadingProgressAnchorOrigin.legacy,
}) {
  return ReadingProgress(
    bookId: 'book',
    lastRead: at,
    currentCharacterIndex: start,
    lastVisibleCharacterIndex: start + 99,
    currentPageIndex: start == 0 ? 1 : 10,
    progress: start == 0 ? 0.001 : 0.5,
    anchorOrigin: origin,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('legacy JSON remains readable with safe defaults', () {
    final decoded = ReadingProgress.fromJson({
      'bookId': 'book',
      'lastRead': '2026-01-01T00:00:00.000Z',
      'progress': 0.4,
      'currentCharacterIndex': 400,
    });

    expect(decoded.schemaVersion, 1);
    expect(decoded.anchorOrigin, ReadingProgressAnchorOrigin.legacy);
    expect(decoded.totalCharacters, isNull);
  });

  test('newer confirmed backward navigation wins', () {
    final local = progress(
      at: DateTime.utc(2026, 1, 1),
      start: 1000,
      origin: ReadingProgressAnchorOrigin.userNavigation,
    );
    final remote = progress(
      at: DateTime.utc(2026, 1, 2),
      start: 500,
      origin: ReadingProgressAnchorOrigin.userNavigation,
    );

    expect(chooseReadingProgress(local: local, remote: remote), remote);
  });

  test('newer automatic legacy beginning cannot replace nonzero local', () {
    final local = progress(at: DateTime.utc(2026, 1, 1), start: 1000);
    final remote = progress(at: DateTime.utc(2026, 1, 2), start: 0);

    expect(chooseReadingProgress(local: local, remote: remote), local);
  });

  test('newer explicit return to beginning is accepted', () {
    final local = progress(at: DateTime.utc(2026, 1, 1), start: 1000);
    final remote = progress(
      at: DateTime.utc(2026, 1, 2),
      start: 0,
      origin: ReadingProgressAnchorOrigin.userNavigation,
    );

    expect(chooseReadingProgress(local: local, remote: remote), remote);
  });

  test('serialized writes keep the newer timestamp', () async {
    final coordinator = ReadingProgressCoordinator();
    final newer = progress(at: DateTime.utc(2026, 1, 2), start: 900);
    final older = progress(at: DateTime.utc(2026, 1, 1), start: 100);

    await Future.wait([coordinator.save(newer), coordinator.save(older)]);
    final stored = await coordinator.read('book');

    expect(stored?.currentCharacterIndex, 900);
    expect(stored?.lastRead, newer.lastRead);
  });
}
