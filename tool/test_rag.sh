#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/rag_native
if [[ "$(uname -s)" == Darwin ]]; then suffix=dylib; shared=-dynamiclib; else suffix=so; shared=-shared; fi
# Match the bundled SQLite version; preserve the archive and source for repeat runs.
if [[ ! -f build/rag_native/sqlite3.c ]] || ! rg -q '#define SQLITE_VERSION +"3.52.0"' build/rag_native/sqlite3.c; then
  curl -fsSL https://www.sqlite.org/2026/sqlite-amalgamation-3520000.zip -o build/rag_native/sqlite.zip
  printf '%s\n' '45d0fea15971dd1300e5b509f48ca134621e10d9297713b64618fbca21b325fa  build/rag_native/sqlite.zip' | shasum -a 256 -c -
  unzip -p build/rag_native/sqlite.zip sqlite-amalgamation-3520000/sqlite3.c > build/rag_native/sqlite3.c
fi
cc -O3 -fPIC "$shared" build/rag_native/sqlite3.c -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS4 -o "build/rag_native/libsqlite3.$suffix"
cc -O3 -fPIC "$shared" packages/memoreader_sqlite_vec/src/sqlite-vec.c -Ipackages/memoreader_sqlite_vec/src -DSQLITE_VEC_OMIT_FS -o "build/rag_native/libsqlite_vec.$suffix"
export MEMOREADER_SQLITE_LIBRARY="$PWD/build/rag_native/libsqlite3.$suffix"
export MEMOREADER_VEC_LIBRARY="$PWD/build/rag_native/libsqlite_vec.$suffix"
flutter test "$@"
