import 'package:flutter/foundation.dart';

/// Represents a sentence and its character range within a larger text.
class SentenceSpan {
  const SentenceSpan({
    required this.text,
    required this.start,
    required this.end,
  });

  /// Inclusive start index in the source string.
  final int start;

  /// Exclusive end index in the source string.
  final int end;

  /// The sentence text (substring of the source).
  final String text;
}

/// Simple sentence segmentation utilities.
///
/// This is a heuristic splitter that looks for sentence-ending punctuation
/// followed by whitespace. It intentionally keeps the implementation light‑
/// weight and avoids heavyweight NLP dependencies.
class SentenceSegmenter {
  // Matches a sentence ending with ., ! or ? followed by whitespace or end of string.
  static final RegExp _sentenceRegex = RegExp(
    r'(.+?[\.\?\!]+)(?=\s+|$)',
    dotAll: true,
  );

  /// Split [text] into a list of [SentenceSpan]s.
  ///
  /// If no sentence boundaries are detected, the whole text is returned as a
  /// single sentence span.
  static List<SentenceSpan> split(String text) {
    final spans = <SentenceSpan>[];

    if (text.trim().isEmpty) {
      return spans;
    }

    final matches = _sentenceRegex.allMatches(text);
    int lastEnd = 0;

    if (matches.isEmpty) {
      // Fallback: treat entire text as one sentence.
      spans.add(SentenceSpan(text: text.trim(), start: 0, end: text.length));
      return spans;
    }

    for (final match in matches) {
      final matchText = match.group(0);
      if (matchText == null) continue;

      final start = match.start;
      final end = match.end;

      // Avoid zero-length or whitespace-only sentences.
      final trimmed = matchText.trim();
      if (trimmed.isEmpty) {
        lastEnd = end;
        continue;
      }

      spans.add(SentenceSpan(text: trimmed, start: start, end: end));
      lastEnd = end;
    }

    // Capture any trailing text after the last match as its own sentence.
    if (lastEnd < text.length) {
      final tail = text.substring(lastEnd).trim();
      if (tail.isNotEmpty) {
        spans.add(SentenceSpan(text: tail, start: lastEnd, end: text.length));
      }
    }

    if (kDebugMode) {
      // Useful during development to inspect segmentation behaviour.
      debugPrint(
        '[SentenceSegmenter] split into ${spans.length} sentences (length=${text.length})',
      );
    }

    return spans;
  }
}

