import '../models/rag_chunk.dart';
import 'rag_token_budget.dart';

/// Question scope is authoritative; optional details must not prolong research.
class RagResearchPolicy {
  static bool needsPlanning(String question, {required bool hasHistory}) {
    final q = question.toLowerCase();
    final complex =
        RegExp(
          r'\b(compare|contrast|difference|connections|chronology|before|after|when|all|every|comparer|différence|tous|toutes|chronologie|avant|après|quand)\b',
        ).hasMatch(q) ||
        question.length > 180;
    final unresolved =
        hasHistory &&
        RegExp(
          r'\b(he|she|his|her|they|their|it|that|those|il|elle|son|sa|ses|cela|lui)\b',
        ).hasMatch(q);
    return complex || unresolved;
  }

  static List<String> requiredFacets(String question) {
    if (RegExp(
      r'^(who (is|was)|qui (est|était))\b',
      caseSensitive: false,
    ).hasMatch(question.trim())) {
      return [
        'Answer the specific question: $question',
        'Identify the person and relevant role without adding unrequested biographical requirements',
      ];
    }
    return ['Answer the specific question: $question'];
  }

  /// Book/genre words added by a planner dilute OR-based name searches.
  static const genericTerms = {
    'book',
    'books',
    'novel',
    'character',
    'system',
    'werewolf',
    'story',
    'livre',
    'roman',
    'personnage',
    'histoire',
  };
  static List<String> lexicalTerms(Iterable<String> terms, String question) {
    final words = question.toLowerCase();
    return terms
        .where(
          (term) =>
              !genericTerms.contains(term.toLowerCase()) ||
              RegExp(
                r'\b' + RegExp.escape(term.toLowerCase()) + r'\b',
              ).hasMatch(words),
        )
        .toSet()
        .toList();
  }

  /// Merge overlapping canonical ranges once, without crossing sections.
  /// Retain the best-ranked stable ID and restore retrieval relevance order.
  static List<RagChunk> compact(Iterable<RagChunk> input) {
    final ranked = input.toList();
    final rank = {
      for (var i = ranked.length - 1; i >= 0; i--) ranked[i].chunkId: i,
    };
    final sorted = ranked.toList()
      ..sort((a, b) {
        final book = a.bookId.compareTo(b.bookId);
        return book != 0 ? book : a.charStart.compareTo(b.charStart);
      });
    final output = <RagChunk>[];
    for (final c in sorted) {
      if (output.isEmpty) {
        output.add(c);
        continue;
      }
      final p = output.last;
      final overlaps =
          p.bookId == c.bookId &&
          p.sectionIndex == c.sectionIndex &&
          p.contentFileKey == c.contentFileKey &&
          c.charStart < p.charEnd;
      final overlapStart = overlaps ? c.charStart - p.charStart : 0;
      final overlapLength = (p.charEnd - c.charStart).clamp(0, c.text.length);
      final consistent =
          !overlaps ||
          p.text.substring(overlapStart, overlapStart + overlapLength) ==
              c.text.substring(0, overlapLength);
      if (!overlaps || !consistent) {
        output.add(c);
        continue;
      }
      if (c.charEnd <= p.charEnd) {
        if (rank[c.chunkId]! < rank[p.chunkId]!) {
          output[output.length - 1] = c.copyWith(
            text: p.text,
            charStart: p.charStart,
            charEnd: p.charEnd,
          );
        }
        continue;
      }
      final offset = p.charEnd - c.charStart;
      final tail = c.text.substring(offset.clamp(0, c.text.length));
      final text = p.text + tail;
      if (RagTokenBudget.count(text, conservative: true) <= 1200) {
        final anchor = rank[p.chunkId]! <= rank[c.chunkId]! ? p : c;
        output[output.length - 1] = anchor.copyWith(
          text: text,
          charStart: p.charStart,
          charEnd: c.charEnd,
        );
      } else {
        output.add(c.copyWith(text: tail, charStart: p.charEnd));
      }
    }
    output.sort((a, b) => rank[a.chunkId]!.compareTo(rank[b.chunkId]!));
    return output;
  }

  static String fingerprint(RagChunk c) =>
      '${c.chunkId}:${c.charStart}:${c.charEnd}:${c.text}';
}
