/// Exclusive canonical-text boundary for spoiler-safe retrieval.
class ReadingBoundary {
  const ReadingBoundary({
    required this.lastVisibleExclusive,
    this.pageStart,
    this.canonicalTextVersion,
  }) : assert(lastVisibleExclusive >= 0);

  final int lastVisibleExclusive;
  final int? pageStart;
  final int? canonicalTextVersion;
}
