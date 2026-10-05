# AGENTS.md — working on whoseware

Rules for any agent (or human) changing this repo. `CLAUDE.md` is a symlink.

whoseware answers "who owns, leads or funds this software?" from an entity
graph embedded in the binary. Being wrong hurts real people and projects, so
the rules on evidence are strict.

## Evidence

- **Every HIT needs a source** (a link) in `data/verdicts.json` or the list
  entry it comes from. No source, no hit.
- Verdicts have a status: `reported` (sourced, not yet reviewed) or
  `verified` (reviewed). Fuzzy matches are always shown as MAYBE, never as HIT.
- Report list memberships as facts ("is on the weird-guys list") and attribute
  the lists' reasons to their authors. Never add contact details or anything
  that facilitates harassment.
- **No gray zones on lineage:** a fork of, or a project led by people from, a
  flagged project is flagged too. Universal infrastructure (kernel, libc,
  compilers, languages, Mesa) is `infra`: mentioned, never scored.
- The lists are fetched at release time and **not redistributed**: only
  names, relations and source links extracted from them go into the graph.

## Code

- Zig 0.16 (`pub fn main(init: std.process.Init)`, `std.Io`). libSQL is
  vendored C (`vendor/libsql`, see its VERSION) compiled once by build.sh.
- `src/build_db.zig` builds the graph; `src/main.zig` is the CLI;
  `src/ngram.zig` (trigram vectors) and `src/db.zig` (libSQL wrapper) are
  shared. Match scoring: names need ≥ 0.80 trigram-cosine similarity.
- **whoseware never uses the network.** The graph changes with releases.
- `ci/check.sh` must pass before merging: unit tests plus `ci/answers.sh`,
  the known answers (a hit, a graph link, fuzzy matches, no noise, hook
  behaviour). Add a case to `ci/answers.sh` for every bug fixed.
- **Releases are tested as users get them, then published**
  (`.github/workflows/release.yml`): `ci/package.sh` makes the tarballs and
  `ci/release-test.sh` checks the *artifacts*, not the tree: checksums, the
  shipped binary, a build from the source tarball with no network, a real
  `makepkg`, and (CI container only) a real `pacman -S` showing the hook fire.
  Locally: `ci/package.sh dist && ci/release-test.sh dist` (set
  `WHOSEWARE_REUSE_LIBSQL=1` to skip the cold libSQL build). **Never run
  `--install` outside CI**: it changes the system. After publishing, CI builds
  the AUR package from the AUR itself.
- `VERSION` is the single version: `build.sh` embeds it in the binary and
  CI fails if `--version` disagrees.
- **A moving "latest" lives in the asset names**, not in a git tag: each
  release carries unversioned copies (`whoseware-x86_64.tar.gz`,
  `whoseware-src.tar.gz`), so `releases/latest/download/NAME` always resolves.
  Consumers (jerkarchy's CI) use that URL, never a pinned version: a new
  release that breaks a consumer is the alarm working.

## Git

Same as jerkarchy: gitflow (main = releases, develop = integration,
feature/* → develop with --no-ff), Forgejo (git.fulgid.us) is the source of
truth, GitHub mirrors main. **No Co-Authored-By or other tool/agent
attribution** in commits, tags or files. Anything reaching main needs the
user's go-ahead.
