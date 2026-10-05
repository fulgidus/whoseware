# whoseware

**Who owns, leads or funds the software you run?**

## Install

**Arch Linux** ([AUR](https://aur.archlinux.org/packages/whoseware)): installs the
binary and a pacman hook that names hits after every install or upgrade.

```
yay -S whoseware
# or, without a helper:
git clone https://aur.archlinux.org/whoseware.git && cd whoseware && makepkg -si
```

**Any x86-64 Linux**: a static binary, nothing else needed. This URL always
serves the newest release:

```
curl -fsSL https://github.com/fulgidus/whoseware/releases/latest/download/whoseware-x86_64.tar.gz | tar -xz
./whoseware-*-x86_64/whoseware --help
```

(Also at `…/releases/latest/download/whoseware-src.tar.gz`: the source with the
release's graph, which builds with no network. Checksums:
`…/releases/latest/download/SHA256SUMS`.)

**From the repository** (needs [Zig](https://ziglang.org) 0.16 and curl):

```
git clone https://github.com/fulgidus/whoseware.git && cd whoseware
./build.sh --fetch      # fetches the lists, builds libSQL (once, ~2 min), the graph, the CLI
zig-out/whoseware --help
```

**Update:** `yay -Syu`, or fetch the latest release again. The graph is part of
the binary and changes with each release; whoseware never uses the network
itself.

## What it does

`whoseware` checks packages against an entity graph — people, companies,
projects and packages, and who maintains, founded, funds or forked what — built
from two lists of software run or funded by people the lists' authors consider
far-right:

- [~rabbits/fashware](https://git.sr.ht/~rabbits/fashware)
- [weird little guys of FOSS](https://drewdevault.com/weird-guys/) (Drew DeVault)

```
$ whoseware neovim terraform helix
neovim                 HIT   adjacency: maintainer Justin M. Keyes is on the weird-guys list (…)
                       alternatives: helix, vim
                       verified 2026-10-05 · https://drewdevault.com/weird-guys/
terraform              MAYBE no verdict; a similar name links to a listed entity (unverified):
                       terraform ≈ Terraform (project, 100% similar) ← known for by: Mitchell Hashimoto — on the weird-guys list: https://drewdevault.com/weird-guys/#hashimoto
helix                  clean
```

For each package it reports, in order:

1. **a reviewed verdict** (`data/verdicts.json`): HIT, clean, or universal
   infrastructure (mentioned, never scored), with the axis (adjacency,
   governance, controversy), reason, sources and clean alternatives;
2. **a link through the graph** from the package to anyone listed, as an
   evidence chain;
3. **a fuzzy match** of the package and its upstream's name — trigram full-text
   search ranked by BM25, plus hashed-trigram vector similarity — reported as
   MAYBE with its similarity. Unverified by definition: check the chain.

## Usage

```
whoseware PACKAGE…            verdicts for these packages
whoseware --system            every explicitly installed package (pacman -Qqe)
whoseware --fail-on-hit …     exit 1 if anything is a HIT (for CI)
whoseware --about             what the embedded graph contains
```

The pacman hook (`hooks/whoseware.hook`) runs it after every install or
upgrade: it names hits and maybes, and never blocks a transaction.

## How it's built

The graph is a [libSQL](https://github.com/tursodatabase/libsql) database
(vendored C, compiled in) built at release time by `build_db` from the lists
and the curated files in `data/`, then **embedded in the binary**. whoseware
never touches the network: the graph is updated with each release. The lists
are fetched when a release is built and their text is not redistributed as
such — only the extracted names, relations and source links.

```
./build.sh --fetch     # download the lists, build libSQL (once), the graph, the CLI
ci/check.sh            # build, unit tests, known answers
ci/package.sh dist && ci/release-test.sh dist
                       # the release artifacts, tested as users get them
```

Every release is tested before it is published: checksums, the shipped binary,
a build from the source tarball with the network off, a real `makepkg`, and a
real `pacman -S` in a container to watch the hook fire; afterwards the package
is built again from the AUR itself.

Zig 0.16. X11 license.

## Corrections

A wrong verdict or a missing link: open an issue or a pull request against
`data/verdicts.json` / `data/relations.json`, with sources.
