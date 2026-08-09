# Local RAG and reading-boundary audit

Date: 2026-07-14
Branch: `audit-codex`

## Implementation status

Implemented on `audit-codex`:

- independent answer and embedding provider configuration; Codex/ChatGPT authentication is no longer treated as OpenAI Platform embedding authorization;
- real embedding capability probes with a 24-hour success cache, timeout, dimension validation, and categorized failures;
- a centralized, dated model registry; OpenAI generation now uses Responses with `store: false`, while Mistral and Codex defaults/logging use the audited model choices;
- one spine-ordered canonical EPUB projection with content hash/version, used directly by versioned chunking;
- 250–500-token default chunks, real sentence overlap, canonical ranges, and chapter/section/file metadata;
- schema migration and index manifests covering content, extraction, chunking, configuration, provider/model/dimensions, and index versions, with automatic incompatible-index rebuilds;
- transactional SQLite FTS5 indexing with FTS4/matchinfo fallback, concurrent lexical and semantic retrieval, RRF, term coverage, comparison-book coverage, overlap removal, and calibrated abstention;
- deterministic query planning plus bounded, cached, timed adaptive model planning for complex questions, with fail-safe local fallback and immutable book/boundary scope;
- exclusive last-visible reading boundaries at reader/library call sites, crossing-chunk clipping, exact latest-events suffix windows, and prompt caching by boundary;
- grounded prompts with stable `[S#]` citations, invalid-citation removal, unconditional insufficient-evidence behavior, and expandable source passages in the question UI;
- debug visibility for manifest identity and canonical chunk locations, plus migration, FTS, hybrid retrieval, capability, text-alignment, overlap, and spoiler-boundary regression tests.

Verification after implementation: the complete Flutter suite passes (204 tests). `flutter analyze` reports no errors; its non-zero result is due to 121 pre-existing warnings/information notices across the project.

Still required before production rollout: opt-in live provider smoke tests, a frozen representative book/question evaluation corpus, Android FTS4/FTS5 capability and p50/p95/memory benchmarks on supported devices, calibration of the abstention/planner thresholds, and confirmation that the private Codex/ChatGPT backend is a supported integration for an independent Android app. These are release measurements or external provider decisions and cannot be established by repository-only unit tests.

## Scope and method

This audit follows three connected paths from EPUB extraction through answer generation:

1. book indexing, chunk storage, semantic retrieval, prompt construction, and answer display;
2. reader progress capture, the "already read" filter, and the "latest events" summary;
3. provider authentication, embedding availability, generation endpoints, and model selection.

It is a static code audit supported by the existing focused tests and provider documentation verified online on the audit date. It does not include live provider calls or a representative question/answer benchmark because no test credentials or RAG retrieval/answer-quality evaluation set are present in the repository.

Focused verification run:

```text
flutter test test/rag_chunking_service_test.dart \
  test/rag_database_service_test.dart \
  test/epub_content_resolver_test.dart \
  test/html_text_extractor_test.dart

Result: 20 tests passed.
```

```text
flutter test test/codex_auth_service_test.dart \
  test/codex_embedding_service_test.dart \
  test/rag_embedding_service_factory_test.dart \
  test/codex_summary_service_test.dart \
  test/summary_config_service_test.dart

Result: 16 tests passed.
```

The passing tests validate their existing units, but do not exercise the complete reader-position-to-RAG path or make a real provider-authorized embedding request. In fact, the Codex factory test codifies the unsupported assumption by expecting a signed-in user to receive `CodexEmbeddingService`.

## Executive assessment

The two reported problems share a root cause: the RAG index and the reader do not have a single, versioned representation of book text and reading positions.

The most urgent issue is not retrieval tuning. RAG chunk offsets are produced from flattened TOC chapters, while the reader uses `EpubContentResolver` in spine order. The existing resolver tests explicitly cover spine content missing from `epub.Chapters`; that content can be visible in the reader but absent from the RAG index. Even where the same content is present, trimming and chapter traversal differences can shift all later offsets.

The latest-events cut then compounds this mismatch by passing the start of the visible page and selecting only chunks whose end is before that point. It therefore excludes the visible page and any chunk crossing the boundary. Its precision is limited to whole chunks, currently configured at up to roughly 1,000 whitespace groups, rather than the exact character or sentence boundary.

General answer quality is weakened by dense cosine similarity as the only retrieval signal, a high fixed context count (default 30), no relevance threshold or reranking, no adjacent-context reconstruction, and no answer-level evidence contract. A hybrid dense + lexical approach is feasible on Android with the current `sqflite` stack and is the recommended next retrieval baseline. Model-assisted query planning is also technically possible, but the current model services are remote rather than on-device; it should be an adaptive enhancement, not a mandatory serial call before every search. There are also no end-to-end quality metrics to distinguish retrieval failure from generation failure.

The Codex authentication path adds a separate release-blocking issue. When Codex is selected and ChatGPT sign-in exists, the embedding factory always sends that ChatGPT/Codex bearer token to the public OpenAI Platform `/v1/embeddings` endpoint. OpenAI's current authentication documentation says general OpenAI API calls should continue to use Platform API keys. The app's mocked tests confirm only the request shape, not that a real ChatGPT token is authorized. Consequently, a user can be shown as signed in while automatic RAG indexing fails with an authorization error, and configured OpenAI/Mistral fallback keys are never tried at runtime.

## Findings

### Critical: Codex sign-in does not establish a supported embedding capability

- `CodexEmbeddingService` posts a ChatGPT/Codex OAuth access token to `https://api.openai.com/v1/embeddings` and labels the feature available whenever a refresh token exists.
- `RagEmbeddingServiceFactory` selects that service before checking configured OpenAI or Mistral API keys and does not fall back after a 401/403.
- Settings explicitly promise that ChatGPT sign-in supplies "summaries and RAG embeddings" and describe API keys as optional fallbacks.
- The tests use `MockClient` responses and therefore prove serialization/refresh behavior only; there is no provider-authorized integration test.
- OpenAI documents ChatGPT sign-in as subscription access for Codex surfaces and Platform API keys for general OpenAI API calls. ChatGPT subscriptions and Platform API billing are separate.

Impact: indexing is very likely unavailable for a Codex-only user despite successful authentication. The UI, `isAvailable()` checks, and factory all report a capability that has not been established. The app can persist an index error in the background while the user believes RAG is configured.

### High: completing provider sign-in does not requeue indexing

- The successful Codex sign-in handler selects Codex, reloads settings, and shows a success message; it does not probe embedding capability or restart pending/error index jobs.
- Library initialization retries every non-complete book, so navigating back through a fresh library load may eventually restart work.
- App-start auto-resume only restarts rows still marked `indexing` with incomplete counts, despite its comment saying it handles errors; rows marked `error` or `pending` are skipped there.
- Reader initialization can restart its current book, making recovery depend on a later navigation/lifecycle event rather than successful authentication.

Impact: even with a valid, supported embedding credential added later, indexing does not predictably start at the moment configuration becomes usable. Authentication success and index readiness have no explicit handoff or user-visible state transition.

### High: the Codex summary integration has no documented third-party API contract

`CodexSummaryService` uses the Codex client identifier/device flow and calls `https://chatgpt.com/backend-api/codex/responses`. Public documentation describes ChatGPT sign-in for the ChatGPT desktop app, Codex CLI, IDE extension, and Codex cloud; this audit found no public contract documenting that private `chatgpt.com/backend-api` endpoint as an API for an independent Android app.

Impact: even if it works today, endpoint behavior, accepted models, quotas, headers, and authorization can change without Platform API compatibility guarantees. Treat this route as experimental until OpenAI confirms the integration is supported for this app. A production path should use a documented API and the corresponding credential type.

### High: generation models and endpoints are hard-coded and partly stale

- OpenAI Platform summaries use `gpt-4.1` through Chat Completions. It is still listed, but it is not the current recommended family, and OpenAI recommends Responses for new work.
- Codex summaries hard-code `gpt-5.5`, which current Codex docs call previous-generation; the current family is GPT-5.6.
- Mistral summaries use the moving `mistral-large-latest` alias while comments and debug output incorrectly describe Mistral Small and a 32K context. The current Mistral Large 3 card documents 256K context, while newer Medium 3.5 and Small 4 models also exist.
- Generation temperature/output limits and character-based prompt truncation are hard-coded rather than declared per model capability.

Impact: model upgrades are risky and opaque, logs do not describe the actual request, cache/evaluation reproducibility is weak, and prompt budgets can be unnecessarily conservative or invalid after an alias changes.

### Critical: reader and RAG offsets can describe different text

- `RagChunkingService` traverses flattened `epub.Chapters` and only falls back to sorted HTML files if that traversal yields zero chunks.
- Both reader implementations use `EpubContentResolver`, which prioritizes EPUB spine order and includes readable spine files that are absent from the TOC.
- The reader concatenates every resolved section using `HtmlTextExtractor.extract(html)`; the chunker uses per-chapter extraction with `trimRight()` and does not add an explicit shared section boundary.
- Nested/anchored TOC entries can reference repeated or partial files, while the spine resolver deduplicates/order-resolves content differently.

Impact: chunks may be missing, duplicated, out of order, or assigned character ranges that do not correspond to the reader. Both anti-spoiler filtering and latest-events selection can therefore include future text or omit already-read text.

### Critical: the supplied read boundary is usually the page start

- The reader tracks `_currentCharacterIndex` as the visible page start and `_lastVisibleCharacterIndex` as the page end.
- The question screen receives `_currentCharacterIndex` for the live book and persisted `currentCharacterIndex` for other books.
- The latest-events dialog and its auto-show precheck also receive `_currentCharacterIndex`.
- The library question screen likewise uses persisted `currentCharacterIndex` instead of `lastVisibleCharacterIndex`.

Impact: the current visible page is treated as unread. At the start of a large RAG chunk, the omission can extend substantially farther backward than one page.

### Critical: boundary queries drop a crossing chunk instead of clipping it

`getChunksUpToPosition` and `getLastNChunksUpToPosition` require `charEnd <= boundary`. A chunk that starts before the boundary and ends after it is excluded in full. Simply changing this predicate to `charStart < boundary` would create a spoiler leak because the full crossing chunk would then contain text after the boundary.

Impact: exact cuts are impossible with the current query contract. The fix must retrieve intersecting chunks and return a clipped, non-embedded context segment ending exactly at the canonical boundary.

### High: configured overlap does not overlap chunk text

The chunker adjusts `tokenStart`/`tokenEnd` bookkeeping by `overlapTokens`, but advances directly to the next sentence (or next token slice for a long sentence). It never rewinds the sentence/token cursor. Adjacent chunk texts therefore have no configured overlap.

Impact: facts split across a chunk boundary lose context, while stored token positions imply overlap that does not exist.

### High: retrieval has one noisy signal and no abstention gate

- All candidate chunks are loaded and ranked only by embedding cosine similarity.
- There is no lexical/BM25 signal for names, quotations, rare terms, or exact phrases.
- There is no candidate diversification, reranker, minimum score, score-gap check, or question-type-aware behavior.
- The highest score is exposed internally but not used to decide that evidence is insufficient.

Impact: superficially similar passages can displace the passage that directly answers the question, and the LLM is still asked to answer when all retrieved evidence is weak.

### High: context construction favors volume over coherence

- The default setting is 30 chunks; chunk maximum is 1,000 whitespace-group "tokens".
- Chunks are passed in similarity order, not book/chronological order.
- Adjacent passages are not fetched to complete a scene or explanation.
- Overlapping/redundant results are not deduplicated.
- Multi-book top-K is global, so one book can monopolize the context even when the question asks for comparison.

Impact: prompts can be large, repetitive, temporally scrambled, and costly. The answer model must infer relationships between disconnected excerpts and can merge separate events.

### High: latest events is a chunk window, not an event/reading window

The service summarizes the last ten fully-contained chunks. With current defaults this can represent a long and variable amount of prose. It has no sentence-exact end clipping, token budget, chapter/scene awareness, duplicate removal, or preference for the text closest to the boundary beyond whole-chunk ordering.

Impact: the result can stop too early, reach too far back, or emphasize older events simply because they occupy more context.

### Medium: index compatibility and freshness checks are incomplete

- Query compatibility checks embedding dimension, not exact model/provider identity.
- A completed index is returned without comparing a content fingerprint, extraction version, chunking configuration, or index schema version.
- Changing extraction/chunk settings or replacing book contents does not automatically invalidate a same-sized completed index.
- Query trusts the completed status rather than verifying the stored chunk count and coverage.

Impact: stale or semantically incompatible embeddings can remain silently active.

### Medium: prompt and source contracts are weak

- Prompts label excerpts but do not carry stable source IDs, chapter names, character ranges, or retrieval scores.
- The answer is instructed to use excerpts, but citations are not required and unsupported claims are not programmatically detectable.
- In read-so-far mode, the French prompt does not explicitly require an insufficient-evidence response in its final conditional sentence.
- The UI shows only contributing book titles, not the actual supporting passages or locations.

Impact: users cannot audit an answer, and developers cannot tell whether an error came from retrieval or generation.

### Medium: automated coverage and observability do not measure the reported behavior

There are unit tests for chunking, storage, extraction, and resolver behavior, but none for:

- `RagQueryService` ranking or prompt assembly;
- a chunk intersecting the read boundary;
- equivalence between reader full text and indexed full text;
- latest-events cuts at the start/middle/end of a chunk or page;
- spoiler exclusion;
- retrieval recall, groundedness, abstention, multi-book balance, latency, or context size.

The debug screen shows chunks and index status but not query scores, discarded candidates, boundary clipping, prompt context, or the canonical reader text around a position.

## Android-local hybrid retrieval feasibility

### What the current stack can support

The app already uses `sqflite` on Android and stores one row per RAG chunk. That is enough to add a local SQLite full-text virtual table keyed to each chunk without introducing a new native search engine. Android's supported persistence APIs expose FTS3/FTS4 tables, and SQLite documents FTS3/FTS4 as built-in full-text virtual-table modules. FTS5 has a convenient built-in `bm25()` ranker, but it is a compile-time SQLite feature and should not be assumed to exist in every platform SQLite used by `sqflite`.

Relevant primary documentation:

- [Android: define data using Room entities (FTS3/FTS4)](https://developer.android.com/training/data-storage/room/defining-data)
- [AndroidX FTS4 API](https://developer.android.com/reference/androidx/room/Fts4)
- [SQLite FTS3/FTS4](https://www.sqlite.org/fts3.html)
- [SQLite FTS5 and built-in BM25](https://www.sqlite.org/fts5.html)

Recommended compatibility strategy:

1. at database creation/migration, probe `sqlite_compileoption_used('ENABLE_FTS5')` and attempt a temporary FTS5 table;
2. use FTS5 + `ORDER BY rank`/`bm25()` where verified;
3. otherwise create an FTS4 external-content table and calculate a BM25-like score in Dart from `matchinfo()` data;
4. if neither module is available, retain a clearly measured exact-term fallback rather than failing RAG entirely.

An FTS row should include `chunkId`, canonical chunk text, book/chapter title, and normalized aliases/character names where available. The canonical `rag_chunks` row remains the source of truth; insertion, deletion, and rebuild of the FTS table must be transactional with the index manifest.

### Recommended hybrid pipeline on Android

For the expected library size, both retrieval branches can run concurrently:

1. **Dense branch:** embed the original question and score local stored embeddings as today, initially keeping the top 40–80 candidates.
2. **Lexical branch:** search FTS for quoted phrases, proper names, rare terms, and normalized question terms, keeping the top 40–80 candidates.
3. **Fusion:** combine ranks using reciprocal-rank fusion (RRF), which avoids trying to directly compare cosine and BM25 scales.
4. **Local reranking:** boost exact phrases/names, term coverage, proximity, same-chapter adjacency, and required-book coverage; apply MMR or near-duplicate suppression.
5. **Context construction:** expand only the strongest hit neighborhoods, enforce the read boundary before scoring/context assembly, and fit the final evidence into a token budget.

This is a genuinely hybrid local retriever: the lexical index, stored embeddings, scoring, fusion, boundary enforcement, and context selection all remain on the device. The current query embedding is still obtained from the configured OpenAI/Mistral/Codex embedding endpoint, so the overall feature is not fully offline. A fully offline semantic branch would require a bundled embedding model/runtime, which is outside the current stack.

### Device-performance considerations

The current dense implementation deserializes every candidate embedding and performs an exact `O(chunks × dimensions)` scan in Dart. This is reasonable for one or a few ordinary books but should be benchmarked for large libraries; FTS does not solve dense-scan cost by itself. Do not use lexical results as the only dense prefilter because that would lose semantic-only matches.

Near-term options, in order:

1. keep exact dense scanning but move scoring off the UI isolate, store normalized vectors, avoid repeated allocations, and filter by selected books/read boundary in SQL;
2. cache hot embeddings and benchmark realistic libraries (for example 1k, 5k, 20k, and 50k chunks);
3. only if p95 latency or memory exceeds budget, evaluate a native approximate-nearest-neighbor/vector extension. This would be a stack change and should not precede measurement.

Suggested Android gates on a representative mid-range device:

- lexical top-50 p95 under 100 ms after warm-up;
- dense + lexical + fusion p95 under 500 ms for 5,000 eligible chunks and under 1,000 ms for 20,000;
- no UI-thread jank attributable to scoring;
- bounded peak memory with a documented target (initially 100 MB incremental maximum during retrieval);
- identical spoiler-boundary behavior across both branches.

## Model-assisted query planning analysis

Calling a model before retrieval can improve complex questions, but it is not automatically more efficient. In the current app, `SummaryService` implementations call remote Codex/OpenAI/Mistral models, and OpenAI/Mistral use large answer-oriented models with hard-coded generation settings. There is no bundled Android LLM or structured query-planning interface. A naive planner call would therefore add network latency, quota/cost, another failure point, and potentially unstable free-form output before the existing embedding and answer calls.

Useful planner outputs are narrow and structured:

- intent: factual, chronology, comparison, character identity, quotation, or multi-hop;
- exact lexical phrases and entities that must be preserved;
- up to three semantic paraphrases/subqueries;
- target books/characters only from the user's selected scope;
- optional translation of search terms into the book language;
- temporal constraints such as "before X" or "after Y";
- whether evidence must come from multiple books or multiple passages.

The planner must never choose or relax the read boundary. Book selection and spoiler filtering are hard constraints applied outside the model. Its JSON must be parsed as untrusted input, capped in size/count, and fall back to the original query on any error.

Recommended routing policy:

1. always create a zero-network deterministic plan locally (Unicode/diacritic normalization, quoted-phrase extraction, proper-name preservation, localized stop-word handling, and safe FTS syntax);
2. run original-question dense retrieval and deterministic lexical retrieval immediately and in parallel;
3. invoke a dedicated remote planner only for questions classified as complex (comparison, multi-hop, ambiguous temporal relation, cross-language terminology) or when the first-pass confidence/coverage is low;
4. where invoked up front, run it in parallel with the original question embedding/search rather than adding it as a fully serial prerequisite;
5. merge planner expansions as additional candidates via RRF; never replace the original query;
6. cache plans by normalized question, selected books, language, planner version/model, and read-boundary version where relevant.

An alternative such as HyDE (generate a hypothetical answer and embed it) should be evaluated only as an experiment. It can help semantic recall but is risky for fiction because invented names/events can steer retrieval toward a false premise. Bounded multi-query expansion is safer and easier to inspect.

The recommended default is therefore **hybrid retrieval first, adaptive model planning second**. A mandatory planner call for every question should only be enabled if the evaluation corpus shows enough retrieval gain to justify its p95 latency, failure rate, and provider cost.

## Provider authentication and model audit (verified 2026-07-14)

### Credential and capability conclusion

Summary generation and embedding generation must be configured as separate capabilities. A provider login is not proof that every endpoint from that vendor is available. In particular, the app must not use a ChatGPT/Codex token for OpenAI Platform embeddings. Relevant official documentation:

- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth): ChatGPT sign-in provides subscription access to Codex, while general OpenAI API calls use Platform API keys.
- [ChatGPT subscription versus API](https://help.openai.com/en/articles/8156019-how-can-i-move-my-chatgpt-subscription-to-the-api): API service is billed and managed separately.
- [OpenAI Responses migration](https://developers.openai.com/api/docs/guides/migrate-to-responses): Responses is recommended for new projects; Chat Completions remains supported.

Recommended supported configurations are therefore:

| Generation capability | Embedding capability | Status |
| --- | --- | --- |
| OpenAI Platform API key | Same OpenAI Platform API key | Supported baseline |
| Mistral API key | Same Mistral API key | Supported baseline |
| ChatGPT/Codex sign-in | Explicit OpenAI Platform or Mistral API key | Only if the Codex summary route is confirmed supported; never assume the ChatGPT token can embed |
| Any generation provider | A future bundled Android embedding model | Fully local semantic option, requiring a new runtime/model and reindex |

Do not silently switch embedding providers at query time: stored document embeddings and question embeddings must use the exact same provider/model/dimensions. Fallback is safe only before indexing starts, or after selecting a compatible existing index; otherwise it requires reindexing.

### Current model recommendations

| Path | Current code | Recommendation | Rationale |
| --- | --- | --- | --- |
| OpenAI answer/latest-events generation | `gpt-4.1`, `/v1/chat/completions` | Migrate to `/v1/responses`; benchmark `gpt-5.6-terra` as the default, `gpt-5.6-sol` as an optional highest-quality profile, and `gpt-5.6-luna` for structured query planning/extraction | [OpenAI's current model guide](https://developers.openai.com/api/docs/models) positions Sol for maximum capability, Terra for intelligence/cost balance, and Luna for high-volume cost-sensitive work. Use evaluation results, not recency alone, as the release gate. |
| Codex subscription generation | `gpt-5.5`, private ChatGPT backend | Do not ship this as a guaranteed provider until OpenAI confirms the endpoint/client flow for this Android app. If retained experimentally, capability-probe it and prefer a provider-resolved/recommended model; evaluate `gpt-5.6-terra` for normal summaries and `gpt-5.6-luna` for structured planner work if the backend advertises them | [Current Codex model guidance](https://learn.chatgpt.com/docs/models) calls 5.5 previous-generation and positions Terra as the everyday successor and Luna for clear, repeatable structured work. Public model availability does not itself make the private backend a supported third-party API. |
| OpenAI embeddings | `text-embedding-3-small`, 1536 dimensions | Keep as the mobile baseline. Evaluate `text-embedding-3-large` with an explicit shortened dimension (for example 1024 or 1536) only if the frozen retrieval corpus shows material gain within Android memory/latency budgets | [OpenAI embedding guidance](https://developers.openai.com/api/docs/guides/embeddings) still lists the two v3 models, supports the `dimensions` parameter, and documents 8192-token input limits. Full 3072-dimensional vectors roughly double local vector storage and scan work versus 1536. |
| Mistral answer/latest-events generation | `mistral-large-latest` | Make the model configurable. Benchmark pinned `mistral-large-2512` for quality, `mistral-medium-3-5` for a quality/cost profile, and `mistral-small-2603` for planner/fast mode; keep `mistral-large-latest` only as an opt-in moving alias with an evaluation gate | Official cards document [Mistral Large 3](https://docs.mistral.ai/models/model-cards/mistral-large-3-25-12), [Mistral Medium 3.5](https://docs.mistral.ai/models/model-cards/mistral-medium-3-5-26-04), and [Mistral Small 4](https://docs.mistral.ai/models/model-cards/mistral-small-4-0-26-03). Pinning improves reproducibility; aliases reduce maintenance but can change behavior. |
| Mistral embeddings | `mistral-embed`, 1024 dimensions | Keep. Record the resolved model/version and capability response, and rebuild if provider/model/dimensions change | [Mistral Embed](https://docs.mistral.ai/models/model-cards/mistral-embed-23-12) remains supported with an 8K context. There is no newer general-text embedding model in the current catalog that clearly supersedes it. |

Model selection must be a versioned registry rather than constants scattered across services. Each entry should declare provider, documented endpoint, credential type, exact model or moving alias, dimensions where relevant, token/context/output limits, supported request parameters, intended role, last-verified date, and deprecation/replacement metadata. Moving aliases require a startup or scheduled capability check and an evaluation/release gate; embedding aliases should be avoided because a silent change can invalidate the entire local index.

## Improvement plan

### Step 1 — establish the audit branch and baseline

Status: completed by creating and switching to `audit-codex` before the audit.

Before implementation, add a small frozen evaluation corpus of legally usable synthetic/test EPUBs covering spine-only content, nested TOCs, repeated anchors, front matter, images/lists, multilingual prose, and very long sentences. Define 30–50 questions across factual, character, chronology, exact-name, comparison, unanswerable, and read-so-far/spoiler cases.

Record baseline metrics:

- retrieval Recall@5 and MRR;
- answer groundedness and citation correctness;
- correct abstention rate;
- spoiler leakage rate (must be zero);
- boundary error in characters;
- p50/p95 latency and context tokens.

Also record a provider capability matrix using non-persistent smoke requests with developer-owned test credentials. Never put live credentials in unit tests or CI logs.

### Step 2 — separate credentials, capabilities, and model configuration

Before changing retrieval or rebuilding indexes:

1. remove `CodexEmbeddingService` as a route to the OpenAI Platform embeddings endpoint and stop describing ChatGPT sign-in as embedding access;
2. split settings into an explicit generation provider and embedding provider, each showing credential type, last successful capability check, selected model, and actionable failure state;
3. require an OpenAI Platform or Mistral API key for current remote embeddings when Codex generation is selected, unless a future local embedding provider is installed;
4. replace `isConfigured()`/non-empty-key availability with lightweight provider capability probes, while keeping authentication state distinct from network/quota/model health;
5. replace scattered model constants with the versioned provider/model registry described above and store the exact embedding provider/model/dimensions in the index manifest;
6. migrate OpenAI generation to Responses with `store: false`, model-aware token budgets, and structured output support; correct Mistral model/context logging and make both providers configurable;
7. keep the Codex summary path behind an experimental flag until its use by this third-party app is confirmed, with a documented Platform-API alternative;
8. after a successful embedding capability check, explicitly requeue pending/error indexes and reconcile any stale `indexing` rows instead of relying on navigation or app restart;
9. add redacted error taxonomy for authentication, authorization, quota, missing model, deprecation, timeout, and network failures.

Acceptance criteria:

- signing in with ChatGPT alone never reports RAG indexing as available;
- a configured embedding provider must pass a real capability check before a new index job starts;
- making an embedding provider usable deterministically restarts eligible failed/pending jobs and exposes progress without leaving Settings;
- a 401/403 cannot fall through repeated retries or silently select an incompatible provider;
- UI and localized strings accurately distinguish ChatGPT subscription, OpenAI Platform API, and Mistral API credentials;
- provider contract tests cover real opt-in smoke calls, while deterministic unit tests cover request/response/error parsing;
- changing exact embedding identity invalidates/rebuilds the index even when dimensions match;
- generation and planner model changes pass the frozen quality/latency/cost evaluation before becoming defaults.

### Step 3 — introduce one canonical, versioned book-text projection

Create a reusable `CanonicalBookTextService` used by the reader, RAG indexer, summaries, and tests. It should:

- use `EpubContentResolver` and spine order once;
- emit canonical full text plus section/chapter metadata;
- define inclusive/exclusive offset semantics explicitly;
- retain a mapping from canonical offsets to content file/chapter and, where feasible, DOM/CFI anchors;
- store an extraction-version and content hash.

Refactor `RagChunkingService` to accept this projection rather than independently reopening/traversing the EPUB. Add an invariant test that concatenated canonical section text is byte-for-byte identical to the text against which reader offsets are reported.

Acceptance criteria:

- all corpus books have identical reader/index canonical text hashes;
- every chunk range is monotonic, in bounds, and its text equals `canonical.substring(charStart, charEnd)`;
- no spine section is missing or duplicated.

### Step 4 — formalize reading-boundary semantics and exact clipping

Introduce a `ReadingBoundary` value object with at least:

- `pageStart` (resume anchor);
- `lastVisibleExclusive` (furthest text exposed on the current page);
- source/timestamp and canonical-text version.

Use named policies instead of a generic integer:

- manual "read so far" questions: `lastVisibleExclusive`;
- manual latest events: `lastVisibleExclusive`;
- auto-show on reopening: use the saved resume/stop policy explicitly, with a product test documenting whether the resumed page is included;
- library queries: persisted `lastVisibleCharacterIndex`, falling back to `currentCharacterIndex` only for legacy data.

Replace whole-chunk boundary filtering with a context builder that retrieves `charStart < boundary`, clips the crossing chunk to `boundary`, drops empty suffixes, and never embeds or sends post-boundary text. Treat all end positions as exclusive.

Acceptance criteria:

- zero characters beyond the boundary enter a prompt in exhaustive boundary tests;
- a boundary in the middle of a chunk includes the prefix through the exact character;
- start/middle/end-of-page tests agree across native and WebView readers;
- legacy progress has an explicit, conservative fallback.

### Step 5 — repair chunking and index lifecycle

- Implement real sentence overlap (or remove the misleading setting).
- Prefer smaller semantic chunks initially (benchmark approximately 250–500 model tokens with 10–20% overlap) and calculate sizes with a provider-appropriate tokenizer rather than whitespace groups.
- Store chapter/section title, ordinal, content-file key, and canonical range on every chunk.
- Add `contentHash`, `extractionVersion`, `chunkingVersion/configHash`, exact embedding provider/model, and index version to status.
- Automatically rebuild when any compatibility field changes; do not rely on dimension alone.
- Mark completion only when stored coverage/count matches the expected manifest.

Acceptance criteria:

- adjacent chunks meet the configured textual overlap within sentence constraints;
- stale indexes are detected and rebuilt automatically;
- completed indexes have complete, gap-accounted canonical coverage.

### Step 6 — build an Android-compatible hybrid, budgeted retriever

Use a deterministic pipeline:

1. migrate `rag.db` to add a capability-probed FTS5 table or portable FTS4 fallback tied transactionally to chunk rows;
2. build deterministic, escaped lexical queries that preserve quoted phrases/proper names and normalize diacritics without changing the user's meaning;
3. run dense top-50 and lexical top-50 retrieval concurrently, honoring selected-book and exact read-boundary filters in both branches;
4. fuse ranks with RRF, deduplicate near-identical overlaps, and apply deterministic exact-name/phrase, term-coverage, proximity, adjacency, and per-book coverage features;
5. optionally expand one adjacent chunk around high-confidence hits;
6. enforce a context-token budget and diversity constraints per book/chapter;
7. reject/abstain when calibrated relevance and coverage thresholds are not met.

Initially retain exact dense scanning, but move embedding decode/scoring off the UI isolate and benchmark it. Introduce a native ANN/vector dependency only if the measured Android p95/memory gates require it. A local cross-encoder is also optional later; deterministic reranking must remain the supported baseline.

Keep retrieval output structured: chunk/source ID, book, chapter, canonical range, dense score, lexical score, fused/rerank score, and clipped text.

Acceptance criteria:

- meaningful improvement over baseline Recall@5/MRR on the frozen corpus;
- exact-name and quotation questions are not worse than dense-only retrieval;
- unanswerable questions meet the target abstention precision;
- no request exceeds the configured context budget;
- multi-book comparison questions include evidence from each required book when available;
- capability tests pass on the minimum supported Android API and representative vendor devices;
- warm p95 meets the documented lexical and combined-retrieval device budgets without UI jank.

### Step 7 — add adaptive, structured query planning

Create a `QueryPlan` domain model and a `QueryPlanner` interface. Implement two planners:

1. a mandatory local deterministic planner for normalization, exact phrases, proper names, safe lexical terms, and simple intent flags;
2. an optional remote `ModelQueryPlanner` with a small structured JSON response, deterministic/low-temperature settings where providers permit, strict timeouts, and fallback to the local plan.

The model planner may produce at most three semantic subqueries and a bounded set of lexical phrases. It may not change selected books, reading boundaries, or spoiler policy. The original user question must always remain one retrieval query.

Add routing modes to the experiment harness:

- `never`: hybrid retrieval without a model planner;
- `adaptive`: planner only for detected complexity or low-confidence first pass (recommended default candidate);
- `always`: planner for evaluation only until its value is demonstrated.

Run up-front adaptive planning in parallel with original-query embedding/retrieval where possible. Cache successful plans and collect planner latency, parse/fallback rate, added API calls, candidate contribution, and end-to-end retrieval gain.

Acceptance criteria:

- malformed, slow, unavailable, or quota-limited planner calls transparently fall back to the original/local plan;
- planner output can never broaden book or read-boundary scope;
- adaptive planning improves a predefined complex-question slice without degrading the simple-question slice;
- the measured Recall@5/MRR gain justifies the agreed p95 latency and provider-cost budget;
- `always` is not shipped as the default unless it materially outperforms `adaptive`.

### Step 8 — make answer generation grounded and inspectable

- Order final evidence by book and canonical position after retrieval selection, while preserving score metadata separately.
- Require inline excerpt citations such as `[B1:C7]` and validate that cited IDs exist.
- Use a structured generation result (`answer`, `citations`, `insufficientEvidence`) where supported; add a robust parser/fallback otherwise.
- Make the insufficient-evidence instruction unconditional in both languages.
- Show expandable cited excerpts with book/chapter/range in the UI and let users report a poor answer.

Acceptance criteria:

- every factual answer sentence is supported by at least one returned citation in the evaluation set;
- invalid citations are rejected or removed;
- the UI exposes the evidence actually sent to the model.

### Step 9 — redesign latest events around an exact recent-text window

Do not use a fixed chunk count as the product definition. Build a latest-events context ending exactly at the selected boundary:

- retrieve intersecting chunks, clip at the boundary, and deduplicate real overlap;
- walk backward to a configurable model-token/character budget, preferably stopping at a sentence or paragraph boundary;
- weight/select the most recent material and preserve chronological order;
- optionally detect a nearby chapter/scene boundary, but never cross forward past the read boundary;
- tell the model the context is a suffix ending at an exact read boundary and require it not to invent resolutions.

Consider caching by `(bookId, canonicalVersion, boundary, promptVersion, model)` so auto-show does not regenerate unchanged summaries.

Acceptance criteria:

- summary source text ends at the exact boundary in all tests;
- moving the boundary forward by one paragraph makes that paragraph eligible without leaking the following paragraph;
- recency weighting favors the last scene over older context;
- generated summaries contain no facts sourced after the boundary.

### Step 10 — add diagnostics, evaluation gates, and rollout controls

Extend RAG debug tooling to show:

- canonical text hash/version and reader/index alignment;
- query candidates and every score/rank stage;
- local/model query plans, generated subqueries, planner latency/fallbacks, and which candidates each subquery contributed;
- selected, expanded, clipped, and discarded ranges;
- final token budget and exact prompt evidence;
- boundary visualization around the reader position.

Add unit, integration, golden-retrieval, and spoiler-regression tests to CI. Roll out behind a retrieval/index version flag, rebuild indexes in the background, and retain an easy fallback until the evaluation targets and device performance budgets are met.

## Recommended delivery sequence

The safest implementation order is Step 2 first (make indexing authorization truthful), Steps 3–5 next (correctness and data migration), Step 6 next (measurable local hybrid baseline), then Steps 7–9 (adaptive planning, answer grounding, and latest-events quality). Step 10 should be developed throughout and used as the release gate. A practical split is:

1. provider capability separation, truthful Codex UI, model registry, and opt-in live smoke tests;
2. canonical text + alignment tests;
3. boundary object + exact clipping + call-site fixes;
4. index schema/version migration + real chunk overlap;
5. evaluation harness and dense-only baseline;
6. SQLite FTS capability probe/migration, dense + lexical RRF, deterministic reranking, and Android benchmarks;
7. structured query-planner interface, deterministic planner, and `never`/`adaptive`/`always` evaluation;
8. citations, answer grounding, and context-budget UX;
9. latest-events recency window and cache;
10. debug UI, telemetry, staged rollout, and final regression pass.

## Decisions to make during implementation

- Whether auto-show on reopen summarizes through the saved page start (strict resume semantics) or the saved last-visible character (last-exposed semantics). The data model should support both; the chosen behavior needs a product test.
- Whether a local cross-encoder meets the supported devices' latency/memory budget. Hybrid fusion and deterministic reranking should remain the baseline fallback.
- Whether FTS5 is available on every supported deployment. The implementation must retain FTS4 support unless device capability evidence permits narrowing the matrix.
- The complexity/confidence thresholds for invoking the remote planner and the maximum acceptable added p95 latency/API cost. `adaptive` is the recommended candidate, not a foregone conclusion.
- Whether fully offline semantic retrieval is a future product requirement. It would require selecting and shipping an Android embedding runtime/model, which is not part of the current stack.
- Target context budget per answer model/provider. It should be a token budget, not a user-facing chunk-count slider.
- Whether OpenAI confirms the current Codex device-flow/private-backend integration as supported for an independent Android app. Until then it remains experimental, not the only generation path.
- Whether moving generation aliases are acceptable in production. Recommended default: pinned releases for reproducible quality, with explicit upgrade evaluations; never allow an embedding alias to change an existing index silently.
