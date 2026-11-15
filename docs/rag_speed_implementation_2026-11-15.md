# RAG scope, speed and answer style implementation

Implemented after the review in `rag_speed_and_answer_review_2026-11-15.md`.

## Behavior

- Clear standalone questions start hybrid retrieval without a preliminary model
  planning call. Ambiguous follow-ups, comparisons and chronology retain planning.
  The original question remains part of required coverage for all question types.
- Both lexical and semantic retrieval remain, with the existing candidate limits,
  reciprocal-rank fusion, model reranking and maximum five research cycles.
- Exact names/quoted phrases have their own lexical query, separate from broad
  fallback terms. Model-added generic book/genre terms are filtered unless asked.
- Assessments use short request-local passage IDs translated to stable source IDs.
  Overlapping canonical text is compacted without crossing books or sections.
  Conflicting overlapping text is not merged.
- Adjacent context is loaded for broken sentences or explicit model requests,
  including context beyond an already merged range. It is assessed before use.
- Later assessments receive new/changed text and a small validated coverage ledger.
  New facts cannot be manufactured from ledger-only material. Final generation
  still receives original assessed source text, not the model's ledger as evidence.
- Further searches require a material gap and an explicit justification. Unchanged
  evidence and repeated queries do not trigger endless assessments.
- Mistral Large remains the research model with low effort. Assessment output has
  the user-requested 65,536-token ceiling; this is not a target response length.
- Answers default to cohesive paragraphs without inline citations, repeated book
  titles or generic limitations sections. Sources remain available below. English
  and French prompts, continuations, streaming and historical display share this
  presentation. Sources are not removed from saved conversations.
- Combined assessment/writing is implemented behind the compile-time
  `RAG_COMBINED_ANSWER` flag and disabled by default. It publishes an answer only
  after a complete, validated evidence decision. An incomplete decision cannot
  expose an unvalidated answer. This prototype buffers structured output and is
  not yet validated for progressive final-text streaming or live rollout.
- Compact logs now include scope, candidate/input sizes, selection counts and
  requested effort/budget. Detailed decisions remain in local conversation history.
  Optional boundary-context failure no longer discards completed hybrid hits;
  failed empty retrieval is reported as research failure rather than absence of
  evidence. Retrieval failures log classifications without raw questions/passages.

## Verification

- `tool/check_rag_speed.dart`: 40 standalone checks of general/bilingual scope,
  overlapping ranges, source boundaries, ID validation, next-search justification,
  ledger support, answer presentation and guarded combined output.
- `tool/check_rag_reliability.dart`: 25 transport, cancellation, completion,
  history, privacy and progress checks.
- Targeted Dart analysis: no errors or warnings (style information remains).
  Whole-library analysis also found existing warnings outside these changes.
- Android debug build through Gradle and iOS simulator compilation; no Flutter CLI
  commands, simulator installation, uninstall, or application data clearing.

The main update was installed on the verified Fold with `adb install -r`.
Original installation date remained 12 August 2026. Later small reliability/scope
follow-ups are verified in source separately; the phone was left alone once the
user resumed testing.

## Observed phone results

The earlier baseline question `Who is Blake Hunt?` took 159.529 seconds: two
assessments plus planning and writing. In the updated app, a separate
`Who is Blake Hunt again?` attempt completed in 31.153 seconds, with planning
skipped, one successful assessment, nine retained passages and no required gaps.
Assessment used 1,750 output tokens, including 1,463 reasoning tokens; writing
used 601 output tokens. Both finished normally.

A subsequent user-driven attempt with planning completed in 55.973 seconds, also
with one successful assessment and normal final completion. Its question and
boundary were not independently inspected, so it is not a matched benchmark.

An earlier short attempt yielded no candidate log and was followed by separate
user activity. Its interruption/scope and failure cause were not established;
it is excluded from successful latency measurements. Additional failure
classification was added instead of counting that result as a speed improvement.

These are encouraging observations, not a three-run matched median, a complete
grounding evaluation, or evidence that every arbitrary question meets the latency
targets. No blanket performance guarantee or automatic research-model downgrade
is introduced. The user subsequently reported that things were working well and
requested commit and push; further live UI testing was stopped.
