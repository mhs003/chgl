# chgl

Release notes from your commits, written into the changelog you already keep.

```sh
$ chgl --dry-run
## [0.8.0] - 2026-11-15

### Added

- **cli:** add `--dry-run`
```

It finds `CHANGELOG.md` (or `CHANGES.md`, `docs/CHANGELOG.md`, …), reads the
commits since your last release tag, and prepares the next section. Nothing is
written unless you say so.

## Install

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/chgl
```

Needs `git`. No runtime dependencies; not even a network connection.

## Use

```sh
chgl init            # create the changelog, or start an empty one
chgl                 # review it in the editor, then apply
chgl --dry-run       # print the section, change nothing
chgl -i              # force the editor
chgl log --since v0.6.0
```

The editor shows every commit with the decision `chgl` made and why:

```
+ chgl ----------------------------------------------------------------------------------+
  CHANGELOG.md  Keep a Changelog
  v0.7.3..HEAD  0.7.3 -> 0.8.0  5 commits  3 keep  2 skip  0 ask
|
   Keep = written   Skip = left out (reason on the right)   Ask = decide
  > Keep added            add --dry-run
    Keep fixed            stop the menu still drifting
    Keep documentation    explain the config
    Skip maintenance      v0.7.4                                (release commit)
    Skip other            wip stuff                (not a conventional commit)
+-- space keep/skip  p preview  a apply  ? help  q quit ---------------------------------+
```

`space` toggles, `p` previews the exact file, `a` applies, `q` quits with
nothing written. The frame is plain ASCII, so it looks the same everywhere.

## Scripted releases

```sh
chgl --as 1.0.0 --write --bump-version --commit --create-tag
```

That writes the section, updates the version in `Cargo.toml` (or
`package.json`, `pyproject.toml`, `VERSION`), commits only those files as
`chore(release): v1.0.0`, and tags it. It never pushes.

Exit `3` means "nothing to release", so CI can branch on it:

```sh
chgl --write --commit --create-tag || [ $? -eq 3 ]
```

## What it understands

- **Conventional Commits**, grouped into Keep a Changelog sections. `feat` →
  Added, `fix` → Fixed, `!` → Breaking Changes, and the file's own wording
  wins if it already says `Features`.
- **The latest release tag**, not the nearest one: `nightly` is ignored, and a
  shallow clone with no tags falls back to the whole history, loudly.
- **The version** from `Cargo.toml`, `package.json`, `pyproject.toml` or
  `VERSION`; no invention when there is none.
- **Hand-written `[Unreleased]` entries**, which ship with the release instead
  of being duplicated or lost.
- **Reference-style footers** (`[0.8.0]: …/compare/…`), which are updated so
  the new heading is a link rather than literal text.
- **Non-Markdown changelogs and fragment systems** (`.rst`, `.changeset/`) are
  detected and refused rather than half-supported.

## Notes

- The editor needs a terminal; redirected output gets the section on stdout
  instead, so `chgl > notes.md` never captures escape codes.
- Nothing is written without `--write` or an explicit apply in the editor.
- `--commit` records only the changelog (and the bumped manifest) and refuses
  to sweep in unrelated staged work unless you pass `--commit-only`.
- The optional `[polish]` step is the only network call, and it is off by
  default.

Full reference: [DOCS.md](DOCS.md). Design notes: [ARCHITECTURE.md](ARCHITECTURE.md).
