#!/usr/bin/env bash
# ci/release-test.sh DIST [--install] — test the release artifacts from
# ci/package.sh as users get them, not the working tree:
#
#   1. checksums, and the unversioned "latest" copies are byte-identical
#   2. the binary tarball: files present, version, every known answer
#   3. the source tarball: builds with NO lists and NO network (its shipped
#      graph), same version, same answers
#   4. the AUR package: makepkg on pkg/PKGBUILD pointed at that tarball
#      (check() runs inside makepkg), contents of the package
#   5. --install (CI container only: it changes the system): pacman -U the
#      package, then a real `pacman -S neovim` must show the hook naming
#      neovim as a hit
#
# Env: ZIG (compiler), WHOSEWARE_REUSE_LIBSQL=1 (local runs: reuse the
# compiled libSQL object instead of the 2-minute cold build; CI never does).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
dist=$(cd "${1:?usage: ci/release-test.sh DIST [--install]}" && pwd)
INSTALL=0; [ "${2:-}" = --install ] && INSTALL=1
v=$(cat VERSION)
fails=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
step() { printf '\n\033[1;96m▌ %s\033[0m\n' "$*"; }

work=$(mktemp -d); chmod 755 "$work"
trap 'rm -rf "$work"' EXIT

step "checksums and latest aliases"
if (cd "$dist" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then ok "SHA256SUMS verifies every tarball"; else bad "SHA256SUMS"; fi
for n in x86_64 src; do
    if cmp -s "$dist/whoseware-$v-$n.tar.gz" "$dist/whoseware-$n.tar.gz"; then ok "whoseware-$n.tar.gz is the $v release (latest alias)"; else bad "whoseware-$n.tar.gz differs from the versioned file"; fi
done

step "binary tarball"
tar -xzf "$dist/whoseware-$v-x86_64.tar.gz" -C "$work"
b=$work/whoseware-$v-x86_64
for f in whoseware whoseware.hook LICENSE README.md; do [ -e "$b/$f" ] && ok "contains $f" || bad "missing $f"; done
[ "$("$b/whoseware" --version)" = "whoseware $v" ] && ok "--version is $v" || bad "--version: $("$b/whoseware" --version)"
ci/answers.sh "$b/whoseware" || fails=$((fails + 1))

step "source tarball: builds with no lists and no network"
tar -xzf "$dist/whoseware-$v-src.tar.gz" -C "$work"
s=$work/whoseware-$v
[ -s "$s/src/gen/entities.db" ] && ok "ships the graph" || bad "no graph in the source tarball"
[ ! -e "$s/build/lists" ] && ok "ships no list text" || bad "ships build/lists"
if [ "${WHOSEWARE_REUSE_LIBSQL:-0}" = 1 ] && [ -f build/libsql.o ]; then mkdir -p "$s/build" && cp build/libsql.o "$s/build/"; fi
# unshare -n: no network namespace, if we're allowed to make one
nonet=(); if unshare -rn true 2>/dev/null; then nonet=(unshare -rn); fi
if (cd "$s" && "${nonet[@]}" ./build.sh >"$work/build.log" 2>&1); then ok "./build.sh (${nonet:+network off, }shipped graph)"; else bad "build from source tarball"; tail -8 "$work/build.log" | sed 's/^/        /'; fi
if [ -x "$s/zig-out/whoseware" ]; then
    [ "$("$s/zig-out/whoseware" --version)" = "whoseware $v" ] && ok "built binary reports $v" || bad "built binary version"
    ci/answers.sh "$s/zig-out/whoseware" || fails=$((fails + 1))
fi

step "AUR package (makepkg on pkg/PKGBUILD, source = the tarball above)"
if [ "$(id -u)" = 0 ]; then
    id builder >/dev/null 2>&1 || useradd -m builder
    asbuilder() { su builder -c "$*"; }
else
    asbuilder() { bash -c "$*"; }
fi
mkdir "$work/pkg" && cp "$dist/whoseware-$v-src.tar.gz" "$work/pkg/"
sha=$(sha256sum "$dist/whoseware-$v-src.tar.gz" | cut -d' ' -f1)
sed -e "s/@VERSION@/$v/" -e "s/@SHA256@/'$sha'/" -e "s|^source=.*|source=(\"whoseware-$v-src.tar.gz\")|" pkg/PKGBUILD > "$work/pkg/PKGBUILD"
chown -R "$(id -u builder 2>/dev/null || id -u)" "$work/pkg" 2>/dev/null || true
if asbuilder "cd '$work/pkg' && ZIG='${ZIG:-zig}' makepkg -f --noconfirm >makepkg.log 2>&1"; then ok "makepkg (build() and check() passed)"; else bad "makepkg"; tail -12 "$work/pkg/makepkg.log" | sed 's/^/        /'; fi
pkgfile=$(ls "$work"/pkg/*.pkg.tar.zst 2>/dev/null | head -1)
if [ -n "$pkgfile" ]; then
    contents=$(tar -tf "$pkgfile")
    for f in usr/bin/whoseware usr/share/libalpm/hooks/whoseware.hook usr/share/licenses/whoseware/LICENSE; do
        printf '%s\n' "$contents" | grep -qx "$f" && ok "package contains $f" || bad "package lacks $f"
    done
fi

if [ "$INSTALL" = 1 ]; then
    step "installed on a real system (CI container)"
    if [ "${GITHUB_ACTIONS:-}" != true ] || [ "$(id -u)" != 0 ]; then
        echo "  --install changes the system: it only runs inside CI's container" >&2; exit 2
    fi
    if pacman -U --noconfirm "$pkgfile" >"$work/pacman-U.log" 2>&1; then ok "pacman -U"; else bad "pacman -U"; tail -8 "$work/pacman-U.log" | sed 's/^/        /'; fi
    command -v whoseware >/dev/null && ok "whoseware is on PATH" || bad "not on PATH"
    [ -f /usr/share/libalpm/hooks/whoseware.hook ] && ok "hook installed" || bad "hook missing"
    out=$(pacman -S --noconfirm --needed neovim 2>&1)
    if printf '%s\n' "$out" | grep -qE 'neovim +HIT'; then ok "a real pacman -S neovim shows the hook naming it a HIT"; else bad "pacman hook did not fire on install"; printf '%s\n' "$out" | tail -12 | sed 's/^/        /'; fi
fi

echo
[ "$fails" -eq 0 ] && { printf '\033[1;32mrelease artifacts passed\033[0m\n'; exit 0; }
printf '\033[1;31m%d check(s) failed\033[0m\n' "$fails"; exit 1
