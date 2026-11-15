// Real policy, context and model-protocol checks without a Flutter invocation.
import 'dart:convert';
import 'dart:typed_data';
import 'package:memoreader/models/rag_chunk.dart';
import 'package:memoreader/services/query_planner.dart';
import 'package:memoreader/services/rag_agent.dart';
import 'package:memoreader/services/rag_answer_style.dart';
import 'package:memoreader/services/rag_generation.dart';
import 'package:memoreader/services/rag_research_policy.dart';
import 'package:memoreader/services/summary_service.dart';

int checks = 0;
void check(bool value, String name) {
  if (!value) throw StateError(name);
  checks++;
  print('PASS $name');
}

class Service implements SummaryService, RagGenerationService {
  Map<String, dynamic> response = {};
  String status = 'complete';
  final requests = <RagGenerationRequest>[];
  @override
  String get serviceName => 'fixture';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<String> generateSummary(
    String text,
    String language, {
    String? bookId,
    void Function()? onCacheHit,
  }) async => throw StateError('legacy interface used');
  @override
  Stream<RagGenerationEvent> generateRag(RagGenerationRequest request) async* {
    requests.add(request);
    yield RagGenerationEvent('text', {'text': jsonEncode(response)});
    yield RagGenerationEvent('completed', {
      'status': status,
      'finishReason': status == 'complete' ? 'stop' : 'length',
    });
  }
}

RagChunk chunk(
  String id,
  String text,
  int start, {
  int section = 0,
  String book = 'book',
}) => RagChunk(
  chunkId: id,
  bookId: book,
  text: text,
  embedding: Float32List(0),
  embeddingDimension: 0,
  sectionIndex: section,
  charStart: start,
  charEnd: start + text.length,
  tokenStart: 0,
  tokenEnd: 0,
  createdAt: DateTime.utc(2026),
);
Map<String, dynamic> decision({
  List<String> keep = const ['p1'],
  bool sufficient = true,
  List<String> gaps = const [],
  String reason = '',
  List<String> expand = const [],
}) => {
  'keep_ids': keep,
  'drop_ids': [],
  'sufficient': sufficient,
  'gaps': gaps,
  'continuation_reason': reason,
  'expand_ids': expand,
  'semantic_queries': ['target missing fact'],
  'lexical_queries': [
    ['Novel', 'Hunt'],
  ],
  'facts': [
    {'text': 'A supported fact.', 'sources': keep},
  ],
};
Future<void> main() async {
  for (final q in [
    'Who is Blake Hunt again?',
    'What does the red seal mean?',
    'Explain the treaty.',
    'Où se trouve la ville ?',
  ]) {
    check(
      !RagResearchPolicy.needsPlanning(q, hasHistory: false),
      'direct retrieval: $q',
    );
  }
  for (final q in [
    'Compare the two treaties.',
    'When did the city fall?',
    'What happened before the treaty?',
    'Comparez tous les événements avant la guerre.',
  ]) {
    check(
      RagResearchPolicy.needsPlanning(q, hasHistory: false),
      'complex scope: $q',
    );
  }
  check(
    RagResearchPolicy.needsPlanning('Why did she refuse it?', hasHistory: true),
    'ambiguous follow-up planned',
  );
  check(
    !RagResearchPolicy.needsPlanning(
      'What does the red seal mean?',
      hasHistory: true,
    ),
    'explicit follow-up avoids unnecessary planning',
  );
  final plan = await const DeterministicQueryPlanner().plan(
    'Who is Blake Hunt again?',
  );
  check(
    plan.lexicalQueries.first == '"Blake Hunt"' &&
        plan.lexicalQueries.length == 2,
    'exact name and separate broad fallback',
  );
  check(
    RagResearchPolicy.requiredFacets(
      'Why did the treaty fail?',
    ).single.contains('Why did the treaty fail?'),
    'non-character question scope preserved',
  );
  check(
    RagResearchPolicy.lexicalTerms([
          'novel',
          'Hunt',
          'system',
        ], 'Who is Hunt?').join() ==
        'Hunt',
    'generic planner additions excluded',
  );
  check(
    RagResearchPolicy.lexicalTerms([
      'system',
    ], 'How does the system work?').contains('system'),
    'explicit topic words preserved',
  );
  final a = chunk('a', 'ABCDEFGHIJ', 0);
  final b = chunk('b', 'FGHIJKLMNO', 5);
  final merged = RagResearchPolicy.compact([b, a]);
  check(
    merged.length == 1 &&
        merged.single.text == 'ABCDEFGHIJKLMNO' &&
        merged.single.charStart == 0 &&
        merged.single.charEnd == 15 &&
        merged.single.chunkId == 'b',
    'overlap merged with exact range and highest ranked stable ID',
  );
  check(
    RagResearchPolicy.compact([
          a,
          chunk('x', 'FGHIJKLMNO', 5, section: 1),
        ]).length ==
        2,
    'sections never merged',
  );
  check(
    RagResearchPolicy.compact([
          a,
          chunk('x', 'FGHIJKLMNO', 5, book: 'other'),
        ]).length ==
        2,
    'books never merged',
  );
  check(
    RagResearchPolicy.compact([a, chunk('conflict', 'xxxxxKLMNO', 5)]).length ==
        2,
    'conflicting overlapping text is not merged',
  );
  final contained = RagResearchPolicy.compact([chunk('best', 'CDE', 2), a]);
  check(
    contained.single.chunkId == 'best' && contained.single.text == a.text,
    'contained hit preserves preferred ID and complete context',
  );
  check(
    ragDisplayAnswer('A fact [S1][S22]. Another fact.') ==
        'A fact. Another fact.',
    'inline citations removed cleanly',
  );
  check(
    ragAnswerStyle('en').contains('cohesive') &&
        ragAnswerStyle('fr').contains('paragraphes'),
    'localized cohesive prose instructions',
  );
  for (final question in [
    'Who is responsible for the sabotage, and why?',
    'Compare the two rescue attempts and their consequences.',
    'What happened before and after the bridge collapsed?',
    'Quote the warning exactly.',
    'Pourquoi le traité a-t-il échoué malgré la promesse ?',
  ]) {
    check(
      RagResearchPolicy.requiredFacets(
        question,
      ).any((facet) => facet.contains(question)),
      'full question preserved: $question',
    );
  }
  final service = Service()..response = decision();
  final agent = ModelRagAgent(service, 'en');
  var result = await agent.assess(
    'Why did the treaty fail?',
    [a],
    ['Cause'],
    1,
  );
  check(
    result.sufficient &&
        result.keepIds.single == 'a' &&
        result.facts.single['sources'].single == 'a',
    'short aliases validated and translated to stable IDs',
  );
  check(
    !service.requests.last.prompt.contains('"id":"a"') &&
        service.requests.last.prompt.contains('"id":"p1"'),
    'protocol hides long source IDs',
  );
  check(
    result.nextPlan.semanticQueries.isEmpty,
    'sufficient decision cannot schedule more searches',
  );
  service.response = decision(sufficient: false, gaps: ['Missing cause']);
  result = await agent.assess('Why?', [a], ['Cause'], 2);
  check(
    result.nextPlan.semanticQueries.isEmpty,
    'continuation requires explicit justification',
  );
  service.response = decision(
    sufficient: false,
    gaps: ['Missing cause'],
    reason: 'The cause changes the explanation.',
    expand: ['p1'],
  );
  result = await agent.assess('Why?', [a], ['Cause'], 2);
  check(
    result.nextPlan.semanticQueries.isNotEmpty &&
        result.expandIds.single == 'a',
    'material gap permits targeted retrieval and expansion',
  );
  check(
    !result.nextPlan.lexicalQuery.contains('Novel'),
    'generic terms excluded in next-cycle queries',
  );
  agent.priorEvidence = {'prior-stable-id': b};
  agent.ledger = {
    'prior-stable-id': {
      'facts': ['An already validated fact.'],
    },
  };
  service.response = decision(keep: ['p1', 'e1']);
  result = await agent.assess('Why?', [a], ['Cause'], 2);
  check(
    result.keepIds.contains('prior-stable-id') &&
        service.requests.last.prompt.contains('already validated fact') &&
        !service.requests.last.prompt.contains(b.text),
    'later assessment uses compact coverage ledger instead of old text',
  );
  service.response = decision(keep: ['unknown']);
  var rejected = false;
  try {
    await agent.assess('Why?', [a], ['Cause'], 2);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'unknown evidence ID rejected');
  service.response = decision()..['drop_ids'] = ['p1'];
  rejected = false;
  try {
    await agent.assess('Why?', [a], ['Cause'], 2);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'conflicting retain/drop decision rejected');
  service.response = decision()
    ..['facts'] = [
      {
        'text': 'Unsupported.',
        'sources': ['e1'],
      },
    ];
  result = await agent.assess('Why?', [a], ['Cause'], 2);
  check(result.facts.isEmpty, 'facts cannot cite rejected evidence');
  service.response = decision(keep: ['p1', 'e1'])
    ..['facts'] = [
      {
        'text': 'A new unsupported claim about old evidence.',
        'sources': ['e1'],
      },
    ];
  result = await agent.assess('Why?', [a], ['Cause'], 2);
  check(
    result.facts.isEmpty,
    'ledger cannot manufacture new facts without source text',
  );
  agent.combineAnswer = true;
  service.response = decision()
    ..['answer'] = 'A cohesive grounded explanation.';
  result = await agent.assess('Why?', [a], ['Cause'], 1);
  check(
    result.answer == 'A cohesive grounded explanation.' &&
        service.requests.last.prompt.contains('cohesive short paragraphs'),
    'fused response carries answer only after validated evidence decision',
  );
  service.response = decision(
    sufficient: false,
    gaps: ['Cause'],
    reason: 'Missing cause.',
  )..['answer'] = 'Premature answer';
  result = await agent.assess('Why?', [a], ['Cause'], 1);
  check(result.answer == null, 'fused research cannot expose premature answer');
  service.status = 'incomplete';
  rejected = false;
  try {
    await agent.assess('Why?', [a], ['Cause'], 1);
  } on RagGenerationException {
    rejected = true;
  }
  check(rejected, 'truncated fused decision cannot publish unvalidated answer');
  print('$checks speed and evidence checks passed');
}
