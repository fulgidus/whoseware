#!/bin/sh
# build.sh [--fetch] — build whoseware: libSQL (once, cached), the entity
# graph (data/ + the two lists), and the CLI with the graph embedded.
#   --fetch   download the lists first (release builds); otherwise use
#             build/lists/ from an earlier fetch
# Output: zig-out/whoseware. Needs zig 0.16 and curl (for --fetch).
set -eu
cd "$(dirname "$0")"
ZIG=${ZIG:-zig}
TARGET="-target x86_64-linux-gnu"
mkdir -p build/lists zig-out src/gen

if [ "${1:-}" = --fetch ]; then
    curl -fsSL -o build/lists/fashware.md https://git.sr.ht/~rabbits/fashware/blob/main/README.md
    curl -fsSL -o build/lists/weird-guys.html https://drewdevault.com/weird-guys/
fi
[ -s build/lists/fashware.md ] && [ -s build/lists/weird-guys.html ] ||
    { echo "build.sh: no lists in build/lists (run ./build.sh --fetch)" >&2; exit 1; }

# libSQL: 9.5 MB of C, compiled once.
if [ ! -f build/libsql.o ] || [ vendor/libsql/sqlite3.c -nt build/libsql.o ]; then
    echo ":: compiling libSQL (once; ~2 minutes)"
    $ZIG build-obj $TARGET -O ReleaseFast -lc -I vendor/libsql \
        -cflags -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 -- \
        vendor/libsql/sqlite3.c -femit-bin=build/libsql.o
fi

echo ":: building the entity graph"
$ZIG build-exe $TARGET -O ReleaseSafe -I vendor/libsql src/build_db.zig build/libsql.o -lc -femit-bin=build/build_db
build/build_db --out src/gen/entities.db --verdicts data/verdicts.json --relations data/relations.json \
    --fashware build/lists/fashware.md --weird-guys build/lists/weird-guys.html

echo ":: building whoseware"
$ZIG build-exe $TARGET -O ReleaseSafe -I vendor/libsql src/main.zig build/libsql.o -lc -femit-bin=zig-out/whoseware
echo ":: zig-out/whoseware ($(du -h zig-out/whoseware | cut -f1))"
