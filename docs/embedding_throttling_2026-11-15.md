# Coordinated embedding preparation under provider throttling

## Cause

The Fold's OpenAI preparation stopped at 3,603/3,653 passages after one batch of
50 exhausted five short retries. Other batches continued issuing requests during
those retries. A subsequent run reused all 3,603 completed passages and finished
the missing batch. No credentials or vector-storage compatibility failure was
observed in that incident.

## Implementation

- OpenAI and Mistral embedding adapters share a bounded HTTP transport and
  scheduler. Existing endpoints, model IDs, dimensions and Mistral's 100-input
  request batching are preserved. Indexing uses one managed batch at a time;
  interactive query embeddings receive priority at the shared gate.
- The gate persists hashed provider/model/credential identities, request leases,
  cooldowns, failure counts and reported token budgets in SQLite. Transactions
  arbitrate foreground, worker-isolate and background-engine access. Each isolate
  owns its database connection; closing one cannot invalidate another's handle.
  No credential, question, passage text or vector is stored in throttle state.
- Retry-After accepts fractional seconds and HTTP dates; reset hints accept
  millisecond and compound duration strings. Relevant request, token and project
  token reset times are respected. Backoff increases from two seconds up to a
  120-second floor, adds jitter, and never shortens a larger server minimum.
- Successful response headers can pause a large background batch before it
  consumes an unavailable token budget. A small interactive request can use
  sufficient remaining tokens; priority never bypasses a shared cooldown or an
  active request's lease. Separate credential profiles use separate buckets;
  traffic in other apps or unidentifiable shared projects remains provider-controlled.
- Retry count is capped at eight dispatches and a ten-minute background retry
  budget (two minutes for interactive requests). HTTP responses are bounded to
  120 seconds, connection establishment to 30 seconds. Cancellation aborts queued
  waiting or active transport. There is no outer indexing retry loop multiplying
  these attempts.
- Long waits and exhausted retry budgets defer the job with a persisted eligible
  time. Completed staging passages and the previous published index remain intact.
  Foreground timers, startup/resume recovery and platform background work can
  resume it. iOS background execution remains opportunistic.
- Waiting callbacks renew the book lease during active backoff; a deferred worker
  releases its book slot. Expired request leases permit recovery after termination.
  New work respects persisted cooldowns across restart. Quota, authentication,
  authorization, model and invalid-input failures are actionable blocked jobs;
  they are not automatically replayed on every app resume. Manual retry or changed
  configuration can retry them.
- Operational tables/columns are additive. Index version, embedding identity,
  chunking settings and published vectors do not change. No corpus migration or
  re-embedding is required.
- Library preparation labels distinguish provider limits, network retries,
  overload, timeout and scheduled retry. Countdown seconds use the persisted time.
  Billing and credential errors have specific English/French action labels.
- Diagnostics whitelist rate headers, request ID, provider/model, status/code,
  batch size, estimated/actual tokens, attempt, request duration and chosen delay.
  Raw provider error messages, bodies, authorization headers and input text are
  excluded. Embedding response indices and finite vector dimensions are validated
  before a batch can reach the index checkpoint.

Official guidance used: [OpenAI rate limits](https://developers.openai.com/api/docs/guides/rate-limits).

## Validation

- `tool/check_embedding_scheduler.dart`: 46 standalone checks, including actual
  HTTP fixtures, long and repeated 429s, terminal quota errors, non-JSON 503s,
  request ordering, Mistral batching/dimensions, cancellation, elapsed budgets,
  expired leases, priority, durable restart and competing real SQLite isolates.
  The previously exposed cross-isolate connection-lifetime failure was corrected
  and the contention scenario rerun successfully.
- Existing standalone reliability and research suites: 25 + 40 checks pass.
- Targeted analysis: no errors or warnings. Android Gradle build and iOS simulator
  compilation pass. No Flutter CLI commands or simulator installations were used.
- A native database integration regression was added to
  `test/rag_database_service_test.dart`: save 3,603/3,653 staged passages, restart,
  confirm the old generation remains published, discover exactly 50 missing
  ranges, and publish the replacement only after all are saved. It was statically
  analyzed; Flutter engine tests were not executed under the no-Flutter-command
  constraint.
- Phone replacement uses only `adb install -r` for serial R3GL70JLLHK and package
  `com.blaisotbalette.memoreader`. No settings changes, deliberate live rate-limit
  stress, uninstall, data clearing or full-library re-embedding are part of this
  validation.

## Live Fold validation

- Updated serial R3GL70JLLHK (`192.168.86.249:38551`), package
  `com.blaisotbalette.memoreader`, using `adb install -r`. The original install
  date, 2026-08-12 18:08:57, remained unchanged.
- Asked “Who is Blake Hunt again?” against My Werewolf System with the existing
  read-so-far boundary. The saved `embedding_response` event confirms OpenAI
  `text-embedding-3-small`, one input, HTTP 200 on attempt 1, 1,883 ms request
  duration, six actual input tokens, and no provider error.
- Retrieval and context preparation reached assessment at 3,564 ms. One successful
  assessment retained five passages with no unresolved gaps. The complete answer
  finished at 12,826 ms, with normal `stop` termination. The phone was returned
  to that answer after inspecting its diagnostics.
- This confirms the normal live OpenAI embedding path; sustained throttling,
  interruption and recovery remain covered by deterministic fixtures rather
  than deliberately exhausting the user's live API limits.
