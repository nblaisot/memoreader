# RAG live latency investigation — 2026-11-15

## Scope and evidence

Read-only inspection and one user-authorized live question on Samsung SM-F971B,
serial R3GL70JLLHK, package `com.blaisotbalette.memoreader`, over Wi-Fi ADB.
No installation, application reset, provider change, or source-code change.

The initial Flutter log buffer was empty. Resuming the existing activity showed
the reader, and opening Ask a question showed no retained conversation. Therefore
the user's previous exchange and its timings could not be reconstructed. The
numbers below describe the live reproduction only, not that earlier exchange.

Live question: `Who is Blake Hunt again?`
One book: My Werewolf System. Read-so-far enabled, reader at chapter 465.
Configured answer/research provider: Mistral, routed by this build to
`mistral-large-4`; embeddings: `mistral-embed`.

## Observed trace

Submitted at approximately 12:50:59 Europe/Paris. Completion logged at
12:52:24.536.

| Stage | Duration |
| --- | ---: |
| Initial planning | 15,000 ms (timeout) |
| Hybrid retrieval | 784 ms |
| First assessment | 15,002 ms (timeout) |
| Research including context assembly | 30,873 ms |
| Final generation | 54,454 ms |
| First visible answer delta from research start | 85,293 ms |
| Research plus generation | 85,327 ms |

Retrieval diagnostics: query embeddings 220 ms, native dense stage 561 ms,
lexical elapsed timer 775 ms; lexical and semantic paths overlap, so these
numbers must not be added. 68 fused candidates; 24 returned candidates; no
embedding cache hits. Final evidence: 15,905 tokens.

Both planning and assessment logged request abortion at their 15-second limits.
Final stop reason: `assessment_fallback`; `degraded: true`; rounds: 1.
The controller therefore did not complete five model-driven research rounds.

The first answer delta arrived approximately 34 ms before generation completed.
There was effectively no useful progressive answer display in this run.

The completed UI answer stops mid-sentence after identifying Blake as a talented
high-school rugby player. It has no displayed citation. The input is enabled
again, confirming this is the completed result rather than an intermediate
streaming screenshot. Finish reason and provider usage were not recorded, so
output-budget exhaustion is a hypothesis, not an established cause.

## Code findings explaining the trace

- `RagQueryService` still bounds planning and each assessment to 15 seconds,
  after upgrading both from a small model to the answer model.
- Planning timeout falls back to deterministic search. Assessment timeout retains
  the candidate passages and breaks research instead of continuing with a valid
  reranking decision. Subsequent expansion can fill the final evidence budget.
- Mistral planning, assessments, and answers all permit 4,000 output tokens and
  omit an explicit reasoning effort. Actual server reasoning behavior is not
  observable in this trace.
- The Mistral adapter requests streaming, but the parser emits text only. It
  does not record reasoning activity, usage, finish reason, response-header
  timing, first SSE event, or first text delta at the HTTP layer.
- Final generation is outside the 90-second research deadline and has no
  explicit first-text or completion timeout.
- The progress UI continues displaying the retrieval round during assessment
  and generation, so it does not accurately describe the current wait.
- A completed short or truncated answer is not rejected on finish reason;
  only empty text is rejected. Citation sanitation does not establish support.
- Logs include embeddings and timings but omit generation model identity,
  request IDs, and timeout categories. The single printed map can also exceed
  Android's log-entry size, as observed in an earlier investigation.

## Recommended next implementation

1. Preserve the stronger research model. Set explicit, supported reasoning
   effort per stage and compact structured research outputs. Mistral documents
   `low`, `medium`, and `high` for Large 4; benchmark `low` for simple questions
   before choosing quality/latency settings. Do not restore the small research
   model merely to meet the old timeout.
2. Calibrate model deadlines using real response distributions, retaining an
   overall research budget. Avoid spending two full deadlines only to discard
   both results. Begin safe deterministic retrieval concurrently with model
   planning, then apply model-directed searches as available.
3. Make degraded assessment behavior explicit. Do not silently turn reranking
   failure into a nearly full 16K evidence prompt treated as an ordinary success.
4. Record safe, compact per-stage events: model identity, stage, deadline,
   headers/first event/first text/completion timing, provider request ID, usage,
   finish reason, candidate and evidence counts. No passages, questions, keys,
   or reasoning text by default.
5. Handle incomplete streams and token-limit termination explicitly; reserve
   output capacity for the visible answer and never display a cut-off sentence
   as a completed successful answer. Validate continuation behavior before use.
6. Show the actual stage (planning, retrieving, checking evidence, generating),
   and bound final-generation first-text and overall waits.

External verification: Mistral's official reasoning documentation:
https://docs.mistral.ai/inference/conversations/reasoning

The trace establishes that remote model-call waits dominate this reproduction.
It does not separate provider queueing, model reasoning, transport buffering,
or other network delay. Native dense retrieval at 561 ms is also worth profiling
against the local performance target, but is a minor fraction of the 85 seconds.
