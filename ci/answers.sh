#!/usr/bin/env bash
# ci/answers.sh BINARY — what whoseware must say about packages whose answers
# we know. Run against the freshly built binary (ci/check.sh), the binary in
# the release tarball and the one built from the source tarball
# (ci/release-test.sh): all three must agree.
set -uo pipefail
W=${1:?usage: ci/answers.sh BINARY}
fails=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
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
"$W" --about | grep -q 'relations' && ok "--about describes the graph" || bad "--about"
exit $((fails > 0))
