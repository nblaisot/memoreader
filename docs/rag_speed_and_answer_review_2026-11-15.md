# RAG speed and answer-style review — 15 November 2026

## Evidence from the completed phone test

Inspected the completed answer and the selected conversation's diagnostic UI on
Samsung SM-F971B, serial R3GL70JLLHK, package
`com.blaisotbalette.memoreader`. No installation, restart, cancellation, database
export, or data reset was performed during this inspection. Returned to the answer
after reading diagnostics.

Actual saved question: **Who is Blake Hunt?**
Book: My Werewolf System. Provider: Mistral Large 4, low effort.
Attempt: `65826151-50e5-4333-8951-ac0308f0361d`.
Installed package last updated at 13:32:58 Europe/Paris; this is the 8,192-token
assessment build. The subsequent 65,536-token source change is not installed.

| Work | Measured elapsed time |
| --- | ---: |
| Planning HTTP request | 12.491 s |
| First candidate preparation after planning response | about 0.82 s |
| First assessment request | about 54.75 s |
| Second candidate preparation after first decision | about 0.43 s |
| Second assessment request | about 77.28 s |
| Research, controller stopwatch | 145.816 s |
| Final generation, controller stopwatch | 13.634 s |
| Attempt to generation completion | 159.529 s |

Assessment dispatch-to-completion includes header waits and model/transport time;
these figures do not isolate GPU time, provider queueing, or network buffering.
The short candidate-preparation intervals are not standalone cold retrieval
benchmarks: initial retrieval overlaps planning.

| Model call | Input tokens | Output tokens | Included reasoning tokens | Finish |
| --- | ---: | ---: | ---: | --- |
| Planning | 180 | 1,043 | 829 | stop |
| Assessment 1 | 9,320 | 5,324 | 4,407 | stop |
| Assessment 2 | 9,472 | 5,822 | 5,169 | stop |
| Answer | 10,240 | 1,184 | 784 | stop |

Both assessments completed normally below 8,192 output tokens. There was no
output-limit failure or timeout. Research stopped because the soft deadline had
passed after cycle two. A 64K ceiling would not have shortened these calls.

## Established causes and remaining uncertainties

1. **Scope inflation.** The planner turned a character reminder into six facets,
   including titles, plot significance, and class/power mechanics. One semantic
   query presumed an abilities/powers investigation. Lexical queries included
   generic corpus terms such as `novel`, `system`, `character`, and the book title.
   OR-ing these terms dilutes the useful exact-name search.
2. **An unnecessary completeness standard.** The first assessment retained 13
   passages, rejected none, and requested more research for exact age/grade,
   protagonist classification, detailed combat mechanics, and related identity
   questions. Some identity questions can matter; exact age and an exhaustive
   combat explanation were not necessary to answer the user's question.
   This decision caused another 77-second assessment.
3. **Expensive repeated reading.** The controller expands every candidate before
   assessment, up to about 1,200 tokens per window, then applies the overall
   budget. Windows overlap but are not globally range-merged before assessment.
   Later assessments receive previous retained passages again. The trace proves
   two similarly large inputs; the exact fraction of duplicate text has not yet
   been measured.
4. **Verbose protocol.** Decisions repeat long SHA passage IDs in keep/drop/expand
   lists. Compact request-local aliases can reduce protocol tokens while retaining
   stable IDs internally. This is a secondary gain: reasoning dominates output.
5. **The answer prompt explicitly causes the unwanted style.** It requires a
   citation for every factual claim and book titles, and repeatedly frames its
   job around provided excerpts. The resulting answer contains seven bullets,
   dense citation chips, and an unhelpful limitations paragraph. Grounding quality
   of every individual claim has not been independently adjudicated here.

The evidence points first to orchestration and the model's research scope. It does
not justify replacing the database or reindexing the library for this latency issue.

## Recommended implementation, in order

### 1. Constrain the task before optimizing transport

- Classify the requested answer scope, keeping the original question authoritative.
  A character reminder needs identity, relevant background, and the relationship
  that helps the reader recognize the character. Do not automatically require
  age, exhaustive abilities, every plot event, or protagonist taxonomy.
- Separate **required coverage** from optional helpful detail. Only an unresolved
  required fact, identity ambiguity, or material contradiction can justify another
  cycle. Require each requested search to name that gap and the fact it could change.
- Preserve at most two semantic and two lexical searches per cycle, 40 hits each,
  and five cycles maximum. Search broadly; do not define thoroughness by how many
  large-model calls were made.
- Prefer exact full names/phrases, aliases, and relevant relationships in lexical
  search. Exclude book-title and generic genre terms unless actually asked about.
  Keep name/phrase matching distinct from broad fallback terms so common words
  cannot dominate the name lookup.
- Keep Mistral Large 4 with low effort; do not silently downgrade research models.
  Treat 64K as an experimental ceiling, not a latency optimization or usage goal.

### 2. Reduce repeated context while retaining retrieval breadth

- Retain the broad semantic and lexical candidate harvest and rank fusion. Keep
  up to 24 assessment passages and the 12K input ceiling; do not lower recall by
  simply shrinking search hit counts.
- Prefer full original retrieval chunks. Add adjacent sentences when the chunk
  is clearly incomplete; avoid automatically tripling every hit. Merge overlapping
  canonical ranges before sending text. Preserve chapter and book diversity.
- Expand only where comprehension requires it, and assess the added text before
  it can support an answer. Explicit expansion requests must be acted on, rather
  than merely logged; include them in the cycle's bounded retrieval work.
- Use short aliases (`p1`, `p2`, ...) in model requests and decisions. Validate and
  translate these back to stable passage IDs and ranges in the controller/history.
- After cycle one, assess new or changed evidence against a compact ledger of
  validated facts and their source IDs. Resend original text when resolving a
  conflict or checking a claim; never let an unsupported model summary become a
  substitute for source evidence. Record exactly which source text was assessed.
- Stop before another expensive assessment if there is no new evidence, no
  requested expansion, and no unresolved contradiction. A repeated query with a
  different wording is not automatically progress.

### 3. Remove avoidable serial model calls

- For clear standalone questions, begin deterministic hybrid retrieval immediately
  and let the first evidence call perform model reranking, scope/coverage checks,
  and any necessary next-search planning. A separate preliminary model plan is
  unnecessary for an explicit-name reminder. Keep planning for ambiguous follow-ups
  and genuinely complex comparisons. This revises the earlier always-plan design.
- First implement the scoped assessment plus existing final writer as a safe,
  measurable intermediate version. It preserves the clear distinction between
  validated research and final prose.
- Then benchmark a combined evidence-and-answer call: a validated structured
  decision either requests targeted searches or selects evidence and starts the
  final answer in the same response. Do not display speculative prose before a
  valid answer decision. Persist selected sources before visible answer text;
  preserve cancellation, partial output, continuation, and completion validation.
- Keep this combined version behind a rollout flag until its evidence rejection,
  spoiler handling, tool/structured-output streaming, and answer quality match the
  separate version. Removing the writer saved only about 14 seconds in this run;
  fixing the unjustified extra assessment is the larger opportunity.
- Keep real inactivity and connection safeguards. Do not restore short hard
  cancellations to make a slow request appear faster.

### 4. Make the answer read like an answer

- Default to a direct, cohesive explanation in a few connected paragraphs, scaled
  to the question. Use lists only when requested or when comparison requires them.
- Remove visible inline source markers and repeated book titles. Keep source
  selection and claim-to-source support internally, with the assessed passages
  available in the existing Sources section. Citation-free presentation must not
  mean evidence-free generation.
- Do not add a source bibliography in the answer body. The Sources section owns
  that presentation. Historical source snapshots remain available after reindexing.
- Avoid `based on the provided excerpts`, `the excerpts do not tell us`, and generic
  limitations sections. Usually start directly with the answer. When uncertainty
  matters, say `Based on what I was able to find in the text, ...` or identify the
  specific unresolved point naturally. Do not imply an exhaustive search when the
  research stopped with a gap or provider failure.
- For a character reminder, identify the person first, then connect the few most
  useful details. Do not dump every discovered fact or discuss absent details that
  the user did not request.
- Update both English and French prompts, streaming display, continuation prompts,
  and any citation sanitization rules. Maintain explicit incomplete/retry states.

### 5. Verify the gains on the same phone

- Add trace fields for required/optional facets, continuation justification,
  overlapping-range tokens removed, unique input tokens, expansion counts, compact
  ID savings, and per-cycle new/retained evidence. Keep prompts in local history;
  logcat remains compact and excludes private reasoning.
- Run matched tests on the same book and boundary: the Blake reminder, an ambiguous
  follow-up, a multi-hop question, an unanswerable question, and spoiler-boundary
  cases. Preserve model, effort, embedding configuration, and source generation.
- Compare scoped prompts first, then context compaction, then model-call fusion.
  Record cold/warm results separately; obtain at least three matched runs for the
  primary question. Do not attribute a one-off provider fluctuation to a code fix.
- Measure first visible answer text, completion, cycles, input/output/reasoning
  tokens, required-fact coverage, unsupported claims, and source support. Retain
  the goals of median first text below 30 seconds and completion below 60 seconds
  as targets, not predictions. Reject gains achieved by losing essential evidence.
- No index migration or re-embedding is needed for these changes. Any subsequent
  authorized device update must verify device/package and use `adb install -r`.

This document is the review and implementation proposal. No application source
or installed binary was changed as part of this inspection.
