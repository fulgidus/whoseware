#!/usr/bin/env bash
# ci/package.sh DIST — make the release artifacts in DIST from HEAD and the
# built graph (run ./build.sh first):
#   whoseware-VERSION-x86_64.tar.gz   binary, pacman hook, license, readme
#   whoseware-VERSION-src.tar.gz      git archive of HEAD + this release's
#                                     graph (src/gen/entities.db); builds with
#                                     no network: what the AUR package uses
#   whoseware-x86_64.tar.gz, whoseware-src.tar.gz
#                                     the same files without the version, so
#                                     .../releases/latest/download/NAME
#                                     always resolves to the newest release
#   SHA256SUMS                        all four
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?usage: ci/package.sh DIST}
v=$(cat VERSION)
[ -x zig-out/whoseware ] && [ -s src/gen/entities.db ] || { echo "package.sh: run ./build.sh first" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT

mkdir "$d/whoseware-$v-x86_64"
cp zig-out/whoseware hooks/whoseware.hook LICENSE README.md "$d/whoseware-$v-x86_64/"
tar -czf "$out/whoseware-$v-x86_64.tar.gz" -C "$d" "whoseware-$v-x86_64"

git archive --prefix="whoseware-$v/" -o "$d/src.tar" HEAD
mkdir -p "$d/whoseware-$v/src/gen" && cp src/gen/entities.db "$d/whoseware-$v/src/gen/"
tar -rf "$d/src.tar" -C "$d" "whoseware-$v/src/gen/entities.db"
gzip -9 -c "$d/src.tar" > "$out/whoseware-$v-src.tar.gz"

cp "$out/whoseware-$v-x86_64.tar.gz" "$out/whoseware-x86_64.tar.gz"
cp "$out/whoseware-$v-src.tar.gz" "$out/whoseware-src.tar.gz"
(cd "$out" && sha256sum whoseware-*.tar.gz > SHA256SUMS)
ls -la "$out"
