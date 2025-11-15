# Reader pagination performance options

This document outlines concrete strategies to improve the time it takes to open an EPUB in the reader. The current implementation repaginates the whole document every time [`_rebuildPagination`](../lib/screens/reader_screen.dart) runs, which is triggered whenever the layout changes (font size, paddings, screen size) or when a book is opened. The repagination work is performed by [`LineMetricsPaginationEngine`](../lib/screens/reader/line_metrics_pagination_engine.dart), which eagerly iterates through **all** extracted document blocks in `_buildPages()`. Each solution below targets a different bottleneck in that pipeline.

## 1. Lazy, demand-driven pagination

Instead of generating every page up front, restructure `LineMetricsPaginationEngine` so that it only materializes the pages the user needs immediately (current, previous, next). The engine can expose an `ensurePage(int index)` method that incrementally paginates until it covers the requested index and caches the results. Background work (e.g. an `Isolate.run` task) can continue generating subsequent pages while the user is already reading.

*Benefits*
- Users see the first page almost immediately.
- Changing padding or font size only recomputes a narrow window around the current position at first.

*Implementation notes*
- Persist pagination cursors (block index, character offset, token spans) so the engine can resume where it left off instead of restarting from the beginning.
- Update progress UI incrementally (unknown total pages until background pagination finishes).

## 2. Persisted pagination caches per layout

Cache the fully computed pages to disk, keyed by book ID + layout signature (font size, padding, viewport dimensions). When the reader opens a book with a previously-seen layout, hydrate the cache immediately instead of recomputing. Invalidate/refresh the cache only when layout settings change.

*Benefits*
- Eliminates repeated expensive pagination runs when reopening a book.
- Enables near-instant resume for the common “continue reading” scenario.

*Implementation notes*
- Serialize `PageContent` and store it in the application directory (e.g. using `path_provider`).
- Store a hash of the HTML blocks alongside the cache so content edits invalidate stale caches.

## 3. Chunked pagination batches on a background isolate

Keep the existing eager algorithm but move the heavy lifting off the UI thread and stream partial results back to the reader screen. The UI can render as soon as the first batch arrives.

*Benefits*
- Minimal code churn: reuse `_buildPages()` in a worker isolate.
- Still yields the total page count once the isolate finishes.

*Implementation notes*
- Wrap `_buildPages()` so it paginates in small batches (e.g. 10 pages) and sends them through `ReceivePort` messages.
- Merge batches into `_engine` as they arrive; drive the `PageView` from the cache that gradually fills up.

## 4. Reduce redundant repagination triggers

Audit the conditions that call `_scheduleRepagination` in [`ReaderScreen`](../lib/screens/reader_screen.dart). For example, debounce repeated padding/font updates from the settings slider so the engine repaginates only after the user stops dragging. Additionally, skip repagination when `_engine.matches(...)` already reports that the layout has not changed materially.

*Benefits*
- Avoids unnecessary work during quick successive UI changes.
- Provides faster feedback when tweaking settings.

*Implementation notes*
- Wrap slider callbacks with `Timer`-based debouncing before calling `_scheduleRepagination`.
- Cache the last applied `_PageMetrics` and bail out early if new metrics are within a small epsilon.

## 5. Hybrid approach: lazy pagination backed by persisted caches

Combine the demand-driven pagination (solution 1) with persisted caches (solution 2) for the best end-to-end experience. When a
book is opened, the engine should first consult the on-disk cache. If a cache hit occurs, hydrate the engine immediately and
resume background pagination only for any missing tail pages. On a cache miss, start by lazily materializing the current window
of pages so the reader becomes interactive at once, then let the background worker paginate and serialize the rest.

*Benefits*
- Opening a previously seen layout is instantaneous because pages stream from disk into memory.
- First-time openings are also fast: only a handful of pages are calculated before the UI responds.
- Background pagination keeps caches fresh without blocking the UI.

*Implementation notes*
- Introduce a `PaginationCache` abstraction that wraps disk IO and exposes `loadWindow`, `loadAll`, and `saveBatch` methods.
- Feed cache hits directly into `LineMetricsPaginationEngine.ensurePage` to avoid recomputation.
- When background pagination generates new batches, append them to both the in-memory cache and the disk-backed cache.

Combining solutions 1 and 2 delivers the biggest improvement: users get instant access to the next/previous pages while an
isolate continues paginating the remainder and saves the result for future sessions.
