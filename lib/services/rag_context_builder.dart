import '../models/rag_chunk.dart';
import '../models/reading_boundary.dart';

/// Builds prompt-safe text from retrieved chunks.
class RagContextBuilder {
  const RagContextBuilder();

  List<RagChunk> clipAndDeduplicate(
    Iterable<RagChunk> chunks, {
    ReadingBoundary? boundary,
  }) {
    final ordered = chunks.toList()
      ..sort((a, b) {
        final book = a.bookId.compareTo(b.bookId);
        return book != 0 ? book : a.charStart.compareTo(b.charStart);
      });
    final output = <RagChunk>[];
    final consumedThrough = <String, int>{};

    for (final source in ordered) {
      final boundaryEnd = boundary?.lastVisibleExclusive;
      if (boundaryEnd != null && source.charStart >= boundaryEnd) continue;
      var end = source.charEnd;
      if (boundaryEnd != null && end > boundaryEnd) end = boundaryEnd;

      var start = source.charStart;
      final consumed = consumedThrough[source.bookId];
      if (consumed != null && start < consumed) start = consumed;
      if (start >= end) continue;

      final localStart = start - source.charStart;
      final localEnd = end - source.charStart;
      output.add(
        source.copyWith(
          text: source.text.substring(localStart, localEnd),
          charStart: start,
          charEnd: end,
        ),
      );
      consumedThrough[source.bookId] = end;
    }
    return output;
  }

  List<RagChunk> recentWindow(
    Iterable<RagChunk> chunks, {
    required ReadingBoundary boundary,
    int maxCharacters = 16000,
  }) {
    final safe = clipAndDeduplicate(chunks, boundary: boundary);
    final selected = <RagChunk>[];
    var remaining = maxCharacters;
    for (final chunk in safe.reversed) {
      if (remaining <= 0) break;
      if (chunk.text.length <= remaining) {
        selected.add(chunk);
        remaining -= chunk.text.length;
      } else {
        final start = chunk.text.length - remaining;
        final sentenceStart = chunk.text.indexOf(
          RegExp(r'(?<=[.!?])\s+'),
          start,
        );
        final localStart = sentenceStart >= 0 ? sentenceStart : start;
        selected.add(
          chunk.copyWith(
            text: chunk.text.substring(localStart),
            charStart: chunk.charStart + localStart,
          ),
        );
        remaining = 0;
      }
    }
    return selected.reversed.toList();
  }
}
