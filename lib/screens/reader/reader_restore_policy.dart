import '../../models/reading_progress.dart';

int? resolveRestoreTarget({
  required ReadingProgress? progress,
  required int totalCharacters,
  required int currentContentVersion,
}) {
  if (progress == null) return null;
  final contentVersionMatches =
      progress.contentVersion == null ||
      progress.contentVersion == currentContentVersion;
  final charIndex =
      progress.currentCharacterIndex ?? progress.lastVisibleCharacterIndex;
  if (contentVersionMatches &&
      charIndex == 0 &&
      progress.anchorOrigin == ReadingProgressAnchorOrigin.userNavigation) {
    return 0;
  }
  if (contentVersionMatches && charIndex != null && charIndex > 0) {
    return charIndex;
  }
  final percentage = progress.progress;
  if (percentage != null && percentage > 0 && totalCharacters > 0) {
    return (percentage * (totalCharacters - 1)).round().clamp(
      0,
      totalCharacters - 1,
    );
  }
  return null;
}

bool shouldBlockAutomaticZero({
  required bool userInitiated,
  required int reportedStartCharacter,
  required int? savedTarget,
  required bool restoreWasReady,
}) {
  return !userInitiated &&
      restoreWasReady &&
      reportedStartCharacter <= 0 &&
      savedTarget != null &&
      savedTarget > 0;
}
