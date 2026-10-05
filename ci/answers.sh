#!/usr/bin/env bash
# ci/answers.sh BINARY — what whoseware must say about packages whose answers
# we know. Run against the freshly built binary (ci/check.sh), the binary in
# the release tarball and the one built from the source tarball
# (ci/release-test.sh): all three must agree.
set -uo pipefail
W=${1:?usage: ci/answers.sh BINARY}
# tests never touch the real ~/.config/whoseware
export WHOSEWARE_CONFIG; WHOSEWARE_CONFIG=$(mktemp -u); trap 'rm -f "$WHOSEWARE_CONFIG"' EXIT
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

# -- categories: tags, with reasons ------------------------------------------
expect_out() {  # expect_out DESCRIPTION PATTERN ARGS…  (output must match)
    local d=$1 pat=$2; shift 2
    if NO_COLOR=1 "$W" "$@" | grep -qE "$pat"; then ok "$d"; else bad "$d"; NO_COLOR=1 "$W" "$@" | sed 's/^/        /' | head -6; fi
}
reject_out() {  # reject_out DESCRIPTION PATTERN ARGS…  (output must NOT match)
    local d=$1 pat=$2; shift 2
    if NO_COLOR=1 "$W" "$@" | grep -qE "$pat"; then bad "$d"; NO_COLOR=1 "$W" "$@" | grep -E "$pat" | sed 's/^/        /' | head -3; else ok "$d"; fi
}
expect_out "tags: neovim is [fascism], checked by hand" '^neovim +HIT +\[fascism\]' neovim
expect_out "tags: mise's are inferred from text (~)" '\[fascism~ racism~\]' mise
expect_out "who: a person, the tag and the sentence it rests on" 'right-wing propaganda' who Justin Keyes
expect_out "who: ...marked as checked by hand" '^  \[fascism\].*checked by hand' who Justin Keyes
expect_out "who: ...with the source text's links" 'github.com/neovim/neovim.github.io/issues/501' who Justin Keyes
# Misattributions found in review: the sentence was about someone else, or said the opposite.
reject_out "tags: Hunhold is not tagged fascism (he pushed to denounce it)" '^  \[fascism' who Laslo Hunhold
reject_out "tags: Yarvin is not tagged surveillance (Thiel's Palantir)" '^  \[surveillance' who Curtis Yarvin
reject_out "tags: Rauch is not tagged militarism (someone else's meeting)" '^  \[militarism' who Guillermo Rauch
reject_out "tags: Kling is not tagged fascism (a 'punch nazis' quote)" '^  \[fascism' who Andreas Kling

# -- offline full-text search ---------------------------------------------
expect_out "search: finds entries by their description" 'Heinemeier Hansson' search ethnic cleansing
expect_out "search --tag: keeps one category" 'Berntsson' search --tag racism ethnic
expect_out "search: says when nothing matches" '^nothing matches' search zzzzqqxx
expect_out "tags: lists the seven categories, all on by default" '\[x\] bigotry' tags
[ "$(NO_COLOR=1 "$W" tags | grep -c '^  \[x\]')" = 7 ] && ok "tags: seven categories" || bad "tags: expected seven categories"
expect_out "--about names the sources and their licence status" 'Neither states a licence' --about

# -- setup and category filtering -----------------------------------------
rm -f "$WHOSEWARE_CONFIG"
"$W" helix >/dev/null; [ ! -e "$WHOSEWARE_CONFIG" ] && ok "non-interactive runs flag everything and write no config" || bad "a non-interactive run wrote a config"
printf 'racism 3\nn\n' | "$W" setup >/dev/null
grep -qx 'categories = racism,bigotry' "$WHOSEWARE_CONFIG" && grep -qx 'inferred = no' "$WHOSEWARE_CONFIG" && ok "setup saves the chosen categories (numbers or names) and inferred=no" || bad "setup config: $(cat "$WHOSEWARE_CONFIG" 2>/dev/null)"
expect_out "filter: a package flagged only elsewhere shows as off, with the reason" '^neovim +off +flagged only under categories you turned off: fascism' neovim
reject_out "filter: ...and is not a HIT" '^neovim +HIT' neovim
expect_out "filter: --all-categories ignores the setup" '^neovim +HIT' --all-categories neovim
"$W" --fail-on-hit neovim >/dev/null && ok "filter: --fail-on-hit passes when everything flagged is off" || bad "--fail-on-hit failed on a turned-off category"
[ -z "$(printf 'neovim\n' | "$W" --pacman-hook)" ] && ok "filter: the pacman hook stays quiet about turned-off categories" || bad "the hook spoke about a turned-off category"
printf '\n\n' | "$W" setup >/dev/null
grep -qx 'categories = all' "$WHOSEWARE_CONFIG" && expect_out "setup: Enter accepts everything" '^neovim +HIT' neovim || bad "setup Enter != all"
# the very first interactive run asks once, then never again (needs a pseudo-terminal)
if command -v script >/dev/null; then
    rm -f "$WHOSEWARE_CONFIG"
    out=$( (sleep 1; printf '\n\n') | script -qec "$W helix" /dev/null 2>&1 | tr -d '\r')
    if printf '%s' "$out" | grep -q 'First run' && grep -qx 'categories = all' "$WHOSEWARE_CONFIG"; then ok "first interactive run asks what to flag, and saves it"; else bad "first-run setup"; fi
    out=$( (sleep 1) | script -qec "$W helix" /dev/null 2>&1 | tr -d '\r')
    printf '%s' "$out" | grep -q 'First run' && bad "asked again on the second run" || ok "...and doesn't ask again"
fi
exit $((fails > 0))
