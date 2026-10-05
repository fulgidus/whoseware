#!/usr/bin/env bash
# ci/check.sh — build whoseware and check what it says about packages whose
# answers we know. Uses build/lists from an earlier `./build.sh --fetch`.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }

./build.sh >/dev/null || { echo "build failed"; exit 1; }
${ZIG:-zig} test src/ngram.zig >/dev/null 2>&1 && ok "trigram vectors" || bad "trigram vectors (zig test src/ngram.zig)"
W=zig-out/whoseware
expect() {  # expect DESCRIPTION PACKAGE GREP-PATTERN
    if NO_COLOR=1 "$W" "$2" | grep -qE "$3"; then ok "$1"; else bad "$1"; NO_COLOR=1 "$W" "$2" | sed 's/^/        /'; fi
}
expect "verdict: neovim is a HIT, with alternatives" neovim '^neovim +HIT .*' 
expect "verdict: helix is clean" helix '^helix +clean'
expect "verdict: linux is infrastructure" linux '^linux +infra'
expect "graph: terraform → Mitchell Hashimoto (weird-guys)" terraform 'Hashimoto — on the weird-guys list'
expect "fuzzy: ladybird-git ≈ ladybird → Andreas Kling" ladybird-git '≈ ladybird .*Kling'
expect "fuzzy: brave-bin ≈ brave → Brendan Eich" brave-bin '≈ brave .*Eich'
expect "no noise: dmraid has no link" dmraid '^dmraid +\?'
expect "no noise: ethtool has no link" ethtool '^ethtool +\?'
if "$W" --fail-on-hit neovim >/dev/null; then bad "--fail-on-hit exits 1 on a hit"; else ok "--fail-on-hit exits 1 on a hit"; fi
if printf 'neovim\nhelix\n' | "$W" --pacman-hook | grep -q '^neovim' && printf 'neovim\n' | "$W" --pacman-hook >/dev/null; then
    ok "pacman hook: reports the hit, exits 0"
else bad "pacman hook"; fi
out=$(printf 'helix\n' | "$W" --pacman-hook)
[ -z "$out" ] && ok "pacman hook: silent about clean packages" || bad "pacman hook printed for a clean package: $out"
echo
[ "$fails" -eq 0 ] && { printf '\033[1;32mall checks passed\033[0m\n'; exit 0; }
printf '\033[1;31m%d check(s) failed\033[0m\n' "$fails"; exit 1
