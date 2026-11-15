# MemoReader native vector extension

This local Flutter FFI plugin vendors the unmodified **sqlite-vec v0.1.6** amalgamation from the official `asg017/sqlite-vec` release. It is registered with `sqlite3_auto_extension` through `SqliteExtension.inLibrary` before database connections open. SQL extension loading is never enabled.

- Release: https://github.com/asg017/sqlite-vec/releases/tag/v0.1.6
- Amalgamation archive SHA-256: `99b6ec36e9d259d91bd6cb2c053c3a7660f8791eaa66126c882a6a4557e57d6a`
- SQLite C ABI headers: SQLite 3.50.4, public domain. Runtime SQLite is supplied by the pinned `sqlite3_flutter_libs` dependency (3.52.0).
- sqlite-vec is MIT licensed; see LICENSE.
- Android uses NDK r29 and an explicit 16 KB linker page alignment. Apple targets build a bundled `sqlite_vec.framework` with CocoaPods.
- Desktop tests compile this same extension and SQLite 3.52.0 using `tool/test_rag.sh`. Desktop tests can select compiled libraries with environment overrides; mobile apps use their bundled frameworks by default.

The upstream Flutter wrapper inspected during implementation omitted its native C sources from its published archive. Keeping this small local wrapper makes the exact sources and build settings reproducible.
