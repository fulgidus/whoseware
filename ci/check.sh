#!/usr/bin/env bash
# ci/check.sh — build whoseware (needs build/lists from `./build.sh --fetch`,
# or a shipped graph) and check it: unit tests, then the known answers.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }

./build.sh >/dev/null || { echo "build failed"; exit 1; }
${ZIG:-zig} test src/ngram.zig >/dev/null 2>&1 && ok "trigram vectors" || bad "trigram vectors (zig test src/ngram.zig)"
[ "$(zig-out/whoseware --version)" = "whoseware $(cat VERSION)" ] && ok "--version matches VERSION" || bad "--version ($(zig-out/whoseware --version)) ≠ VERSION ($(cat VERSION))"
ci/answers.sh zig-out/whoseware || fails=$((fails + 1))
echo
[ "$fails" -eq 0 ] && { printf '\033[1;32mall checks passed\033[0m\n'; exit 0; }
printf '\033[1;31m%d check(s) failed\033[0m\n' "$fails"; exit 1
