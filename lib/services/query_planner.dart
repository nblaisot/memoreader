import 'dart:convert';

import 'summary_service.dart';

class QueryPlan {
  const QueryPlan({
    required this.originalQuery,
    required this.semanticQueries,
    required this.lexicalQuery,
    required this.intent,
    required this.isComplex,
  });

  final String originalQuery;
  final List<String> semanticQueries;
  final String lexicalQuery;
  final String intent;
  final bool isComplex;
}

abstract class QueryPlanner {
  Future<QueryPlan> plan(String question);
}

/// Optional adaptive planner for complex questions. Provider output is
/// untrusted, bounded, and always falls back to the deterministic plan.
class ModelQueryPlanner implements QueryPlanner {
  ModelQueryPlanner({
    required this.summaryService,
    required this.language,
    QueryPlanner? fallback,
  }) : _fallback = fallback ?? const DeterministicQueryPlanner();

  final SummaryService summaryService;
  final String language;
  final QueryPlanner _fallback;
  static final Map<String, QueryPlan> _cache = {};

  @override
  Future<QueryPlan> plan(String question) async {
    final cacheKey = '$language:${summaryService.serviceName}:${question.trim().toLowerCase()}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    final baseline = await _fallback.plan(question);
    try {
      final raw = await summaryService.generateSummary(
        '''Return JSON only for retrieval planning. Never answer the question.
Schema: {"semantic_queries":[string],"lexical_phrases":[string],"intent":string}.
Keep the original meaning, add at most 2 rewrites, and at most 8 short exact names/phrases.
Question: $question''',
        language,
      ).timeout(const Duration(seconds: 12));
      final normalized = raw
          .replaceFirst(RegExp(r'^\s*```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '');
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final rewrites = (json['semantic_queries'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value.length <= 240)
          .take(2);
      final semantic = <String>{question, ...rewrites}.take(3).toList();
      final phrases = (json['lexical_phrases'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value.length <= 80)
          .take(8)
          .map((value) => '"${value.replaceAll('"', '""')}"')
          .toList();
      final plan = QueryPlan(
        originalQuery: question,
        semanticQueries: semantic,
        lexicalQuery: phrases.isEmpty
            ? baseline.lexicalQuery
            : <String>{
                ...phrases,
                ...baseline.lexicalQuery.split(RegExp(r'\s+OR\s+')),
              }.take(12).join(' OR '),
        intent: (json['intent'] as String?)?.trim().isNotEmpty == true
            ? (json['intent'] as String).trim()
            : baseline.intent,
        isComplex: true,
      );
      if (_cache.length >= 100) _cache.remove(_cache.keys.first);
      _cache[cacheKey] = plan;
      return plan;
    } catch (_) {
      return baseline;
    }
  }
}

/// Zero-network planner that produces escaped FTS terms and conservative
/// intent flags. It never changes book scope or a reading boundary.
class DeterministicQueryPlanner implements QueryPlanner {
  const DeterministicQueryPlanner();

  static const _stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'by',
    'for',
    'from',
    'how',
    'in',
    'is',
    'it',
    'of',
    'on',
    'or',
    'that',
    'the',
    'this',
    'to',
    'was',
    'what',
    'when',
    'where',
    'which',
    'who',
    'why',
    'with',
    'à',
    'au',
    'aux',
    'avec',
    'ce',
    'ces',
    'dans',
    'de',
    'des',
    'du',
    'en',
    'est',
    'et',
    'la',
    'le',
    'les',
    'où',
    'par',
    'pour',
    'que',
    'qui',
    'quoi',
    'se',
    'sur',
    'un',
    'une',
  };

  @override
  Future<QueryPlan> plan(String question) async {
    final quoted = RegExp(r'''["“”«]([^"“”»]+)["”»]''')
        .allMatches(question)
        .map((match) => match.group(1)!.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final words = question
        .toLowerCase()
        .replaceAll(RegExp(r'''[^\p{L}\p{N}'-]+''', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 1 && !_stopWords.contains(word))
        .take(12)
        .toList();

    String escape(String value) => '"${value.replaceAll('"', '""')}"';
    final lexicalParts = <String>{...quoted.map(escape), ...words.map(escape)};
    final lower = question.toLowerCase();
    final comparison =
        lower.contains('compare') ||
        lower.contains('difference') ||
        lower.contains('compare ') ||
        lower.contains('différence');
    final chronology =
        lower.contains('before') ||
        lower.contains('after') ||
        lower.contains('avant') ||
        lower.contains('après') ||
        lower.contains('when') ||
        lower.contains('quand');

    return QueryPlan(
      originalQuery: question,
      semanticQueries: [question],
      lexicalQuery: lexicalParts.join(' OR '),
      intent: comparison
          ? 'comparison'
          : chronology
          ? 'chronology'
          : quoted.isNotEmpty
          ? 'quotation'
          : 'factual',
      isComplex: comparison || chronology || question.length > 180,
    );
  }
}
