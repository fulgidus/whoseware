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

(More sources are planned: forge ownership and funding, funder pages, public
contract and enforcement records. See Categories and Sources below.)

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

## Categories

Everything in the graph can carry categories, each with the reason it was given:

| category | what it covers |
|---|---|
| `fascism` | dictatorial or authoritarian politics, far-right movements |
| `racism` | racism, antisemitism, white-supremacist and ethno-nationalist views or funding |
| `bigotry` | transphobia, homophobia, misogyny |
| `militarism` | arms makers, war profiteering, military and border-enforcement contracting |
| `surveillance` | mass surveillance, spyware, face recognition, data brokering |
| `ultracapitalism` | billionaires, and companies with serious labour-law violations (wealth and penalty data: planned; today only what the lists say) |
| `misconduct` | harassment, abuse, fraud, rug-pulls |

A tag is **firm** when it is the list's own definition or checked by hand, and
**inferred** (marked `~`) when it comes from keyword rules over an entry's
text. Inferred tags are leads, not verdicts: `whoseware who NAME` shows the
sentence each one rests on. Rules, corrections and suppressions live in
`data/tags.json`.

The first time you run whoseware in a terminal it asks which categories to
flag and whether inferred tags count (Enter accepts everything). Change it
with `whoseware setup`; `whoseware tags` shows what is on. Packages flagged
only under categories you turned off are shown as `off`, never silently
dropped. Scripts, CI and the pacman hook flag everything until you choose.

## Look things up offline

Each entity carries its sources' own text and links in the binary, so no network
is needed:

```
whoseware who "Justin Keyes"        # tags and why, the entry's text, links, connections
whoseware search surveillance       # full-text, ranked by BM25, matches highlighted
whoseware search --tag racism ethnic
```

## Sources and attribution

The graph is built from [~rabbits/fashware](https://git.sr.ht/~rabbits/fashware)
and Drew DeVault's [weird little guys of FOSS](https://drewdevault.com/weird-guys/).
**Neither states a licence.** Their text is included with attribution and links
(every `who` shows where each sentence came from); if an author objects it is
removed in the next release. Every claim about a person or company stays
attributed to its source: whoseware reports what the lists say, with the
reason.

## Usage

```
whoseware PACKAGE…            verdicts for these packages
whoseware --system            every explicitly installed package (pacman -Qqe)
whoseware --fail-on-hit …     exit 1 if anything is a HIT (for CI)
whoseware --about             what the embedded graph contains, and its sources
whoseware setup | tags        choose / show the categories to flag
whoseware who NAME | search WORDS…    offline look-ups (see below)
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
