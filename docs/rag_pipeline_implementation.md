# RAG pipeline implementation

Implemented November 13, 2026. Search remains on the device; configured remote providers generate embeddings, search plans, evidence assessments, and answers.

## Readiness and persistence

`RagIndexingService` is the coordinator: `observe`/`snapshot` read readiness, `startIndexing` enqueues work, and a reusable worker executes jobs. Menus never enqueue indexing. Ready snapshots are delivered without database reads. Unknown readiness does not display indexing. Import and startup/resume recover preparation, and configuration changes schedule a replacement. Library cards expose genuine preparation/failure and retry.

Jobs use bounded concurrency, database-backed expiring leases across foreground/background engines, staged checkpoints, file fingerprints, and an embedding/chunk configuration identity. Compatible active indexes remain searchable during replacement. Android WorkManager and iOS BGProcessingTask continue work opportunistically; foreground recovery is authoritative. iOS background execution is not guaranteed.

RAG opens `rag-v5.db` (schema version 6) through a persistent `sqflite_common_ffi` worker and bundled SQLite. `rag.db` is imported once and retained untouched. Unrelated databases, books, reading progress, and installed applications are preserved. FTS5, native vec0 vectors, source rows, and the active manifest publish in one transaction. Incomplete or invalid staged vectors cannot activate. Manifest generations, stored passage token counts, and previous/next passage links are persisted.

SQLite is pinned through `sqlite3_flutter_libs 0.5.42` (native SQLite 3.52.0); `sqlite3 2.9.4`, `sqflite_common_ffi 2.3.6`, and upstream sqlite-vec v0.1.6 are pinned. The local FFI wrapper contains reproducible source and native build configuration. The extension entry point is registered before connections open; SQL extension loading is never enabled.

## Retrieval and answers

One controller handles single and multiple books. It freezes scope/boundaries and rejects unavailable selections explicitly. It loads active manifests in one query and never rebuilds an index or loads the library's vectors into Dart.

The agent plans up to two semantic queries and two lexical term/phrase lists. Each of up to five cycles performs concurrent lexical retrieval and query embedding, native cosine search, reciprocal-rank fusion, and a full-passage LLM assessment. Each search returns 40 candidates; assessment sees at most 24 passages / 12,000 conservatively budgeted tokens. The model retains/discards passage IDs, identifies gaps, requests adjacent passages, and decides whether to search further. Discarded evidence cannot re-enter through expansion. Previously accepted evidence outside the next assessment window remains eligible within the evidence budget. New discoveries can replace earlier hits.

Initial planning and final answer generation are outside the five cycles. Research has a 90-second deadline; individual planning/assessment calls have a 15-second limit. Repeated searches, no new evidence, sufficient coverage, and cancellation stop earlier. Malformed decisions get one deterministic fallback, with no repair-call loop. Gaps accompany the grounded final prompt. Citation identifiers map to the final source list; invalid identifiers are removed. Answers stream through existing providers. Scoped HTTP abortion reaches active provider requests, and provider clients reuse connections.

Native vector search applies eligible row IDs before top-k selection. FTS5 BM25 uses the same eligible book/read scope. Global scoped SQL is essential: the first per-book implementation took ~2.2 seconds at 10,000 passages and was replaced after benchmarking.

Crossing chunks never contribute their unread vector. Their visible prefixes are searched lexically, and cached prefix vectors are prepared while reading after a three-second debounce. Prefix-cache identity includes model, dimensions, content, chunk configuration, and exact boundary. Expansion clips again before any model receives text.

## Chunking and budgets

Defaults are a 400-token target, 550 maximum, and about 60 tokens of real sentence overlap. Existing explicitly saved preferences are retained. Chunking respects canonical sections and exact UTF-16 offsets, favors paragraph/sentence boundaries, and splits oversized unbroken Unicode text without splitting surrogate pairs. IDs are deterministic over canonical location, text, and chunk version.

cl100k tokenization is exact for the configured OpenAI embedding family. Other tokenizers use a conservative UTF-8 estimate alongside cl100k. Adjacent context expands to at most roughly 1,200 conservatively counted tokens per retained hit. The actual hit is reserved first, then surrounding context. Merged final evidence is capped at 16,000 tokens, reduced against a conservative 32K model context allowance after history, instructions, question, and output reservations.

## Validation and reproduction

Verified in this workspace: **262 tests passed**, with the live-provider evaluation and large benchmark skipped by default; the benchmark was also run separately. The final settings/core subset passed another 19 tests. Static analysis has no errors (113 existing warning/information notices remain). Android debug APK, iOS simulator, and unsigned iOS device builds succeeded. No application was installed or launched on a device.

Run all tests with the pinned native test engine:

```bash
tool/test_rag.sh
```

Run the native benchmark (1, 20, 100 books; default 300 passages per book; 1,536 dimensions):

```bash
tool/test_rag.sh --dart-define=RAG_BENCHMARK=true test/rag_native_benchmark_test.dart
```

Results are written under `build/rag_eval`. The benchmark reopens the connection before its first query; it does not flush the operating system's filesystem cache. Memory snapshots are process RSS, not isolated per-component allocations.

A measured macOS test run with 30,000 passages gave:

| Books | Passages | First query | Warm p95, lexical + native semantic | Previous load + Dart semantic scan |
|---|---:|---:|---:|---:|
| 1 | 300 | 10 ms | 3 ms | 5 ms |
| 20 | 6,000 | 28 ms | 19 ms | 57 ms |
| 100 | 30,000 | 134 ms | 99 ms | 258 ms |

These are desktop measurements, not mobile release guarantees. The old-scan column excludes lexical search and is a baseline component comparison, not an end-to-end answer comparison.

The original synthetic EN/FR corpus has 60 questions, expected evidence/facts, conversational follow-ups, unanswerable questions, and reading boundaries. Offline tests verify lexical probe recall and compare canonical chunk targets of 300/400/550. This small corpus gives 100% whole-gold-passage probe recall for all three settings and cannot establish an optimal chunk size or answer quality on real novels. The 400-token default remains the planned default until representative live evaluation justifies a change.

Opt-in live embedding/agent/judge evaluation:

```bash
MEMOREADER_RAG_API_KEY=... tool/test_rag.sh --dart-define=RAG_LIVE_EVAL=true test/rag_evaluation_test.dart
```

This uses billable provider calls and records quality/timing metadata in `build/rag_eval/live.json`. Credentials are supplied only through the environment and are not saved in fixtures. It is skipped by the normal suite.

## Release gates

Android APK, iOS simulator, and unsigned iOS device builds are verified independently. Android arm64-v8a/x86_64 SQLite and vector libraries have 16 KB ELF LOAD alignment. Builds do not install or launch applications.

Physical Android/iOS release-build latency, memory, UI readiness, real-provider answer completeness, citation support, and representative novel evaluation remain required before production rollout. Background expiration/restart behavior also needs platform execution tests. No mobile p95 or live answer-quality improvement is claimed from unit tests.

Populate a copy of `rag_release_metrics.example.json` with measured device and evaluation results, then run:

```bash
python3 tool/check_rag_release.py path/to/measured-metrics.json
```

Missing measurements block release. Required gates are UI p95 <=200 ms, local hybrid p95 <500 ms, recall >=90%, zero spoiler leaks, no corpus-sized vector loading into Dart, and answer coverage improving on baseline with citation support at least matching baseline. A failed search gate requires a storage-design revision before rollout; ObjectBox/HNSW remains a future alternative rather than an unmeasured automatic fallback.
