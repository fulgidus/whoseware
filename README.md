# whoseware

**Who owns, leads or funds the software you run?**

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
ci/check.sh            # build and check known answers
```

Zig 0.16. X11 license.

## Corrections

A wrong verdict or a missing link: open an issue or a pull request against
`data/verdicts.json` / `data/relations.json`, with sources.
