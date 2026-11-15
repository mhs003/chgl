# Architecture

`chgl` is a single binary. One run does:

```
args ──▶ config ──▶ repo ──▶ detect ──┬─▶ commits ──▶ entries
                                      ├─▶ version ──┐
                                      └─▶ file ─────┴─▶ plan ──▶ render ──┬─▶ stdout (--dry-run)
                                                                          ├─▶ write ─▶ commit ─▶ tag
                                                                          └─▶ TUI (edits plan)
```

There is no daemon, no cache, no state between runs. The optional model call
(polish) is the only network activity and the only step that can be skipped
without changing the result.

## Modules

| File | Responsibility |
| --- | --- |
| `src/main.zig` | Entry point. Parses args, dispatches subcommands (`init`, `config init`, `detect`, `log`), runs the pipeline for the default command, applies the plan. |
| `src/cli.zig` | A flag spec table, a parser for it, and `--help` rendered from the same table, so help and parsing cannot drift. No dependency on an argument library. |
| `src/config.zig` | Config discovery (`--config`, `$CHGL_CONFIG`, `%APPDATA%\chgl` / `$XDG_CONFIG_HOME` / `~/.config/chgl`), TOML and JSON into one struct, defaults, validation, `init`. |
| `src/git/` | `git` CLI wrappers: one NUL-safe log format, semver-filtered tag selection, `rev-parse`, `status --porcelain`, `remote get-url`, `add -- <path>`, `commit -F -`, `tag`. |
| `src/detect.zig` | Which file is the changelog, why, and whether it can be written. Pure given a directory + a name list, so it is testable. |
| `src/init_skeleton.zig` | The file `chgl init` writes, and the checks that decide whether a file may be started or must be left alone. |
| `src/changelog.zig` | Parses a Markdown changelog into blocks, finds the insertion point, inserts a section, absorbs `[Unreleased]`, rewrites link-ref footers. Line-preserving. |
| `src/release.zig` | Commit range → `Entry`s with a `State` (`keep`/`skip`/`ask`); classification into groups; breaking detection; builds the `Plan`. |
| `src/version.zig` | Semver parse/compare/bump, tag-prefix inference, version-source readers and the opt-in writer. |
| `src/render.zig` | Section markdown in Keep a Changelog shape, wrapping and link formatting. |
| `src/util/glob.zig` | `--exclude` matching (`*`, `?`, `[...]`, `{a,b}`). |
| `src/tui/` | The interactive front end: `app.zig` is a pure state machine plus ASCII cell-buffer layout (testable without a terminal), `term.zig` owns the tty, raw mode, key decoding and terminal restore. |
| `src/config/root.zig` | Config discovery (`--config`, `$CHGL_CONFIG`, the platform config dir), TOML first then JSON, strict unknown-key rejection. |

## Data flow

### 1. Config

First match wins: `--config`, `$CHGL_CONFIG`, `%APPDATA%\chgl` (Windows),
`$XDG_CONFIG_HOME/chgl`, `~/.config/chgl`. Inside the directory `config.toml`
is tried before `config.json`.

Every key is optional; unknown keys are errors so a typo fails loudly. The
model section is optional and only needed for `--polish`, which keeps the
whole tool offline by default.

### 2. Repository and range

The range is `last release tag..HEAD`. The tag is the newest tag that parses
as a version under the inferred prefix and is reachable from `HEAD`;
`latest`/`nightly`/prereleases are not release boundaries. `git describe` is
not used for this — it answers a different question.

A shallow clone has no tags, so the range falls back to the whole history,
capped, with a printed notice.

Commits are read with `git log -z --format=%H%x1f%h%x1f%ct%x1f%an%x1f%ae%x1f%P%x1f%s%x1f%b`,
split on `\0` with fields on `\x1f`: subject and body may contain any other
byte. Merge commits are read too, so `--parse-merges` can use them.

### 3. Detection

A tiered scorer: exact root names (`CHANGELOG.md`, `CHANGES.md`, …) beat the
same names in `docs/`, which beat structural evidence. A `.md` that merely
mentions "changelog" is not a candidate. Non-Markdown candidates (`.rst`,
plain `CHANGELOG`, `debian/changelog`) and fragment systems (`.changeset/`,
towncrier) are *detected and refused* with a specific message rather than
silently half-supported. `chgl detect` prints the ranking and the reason.

### 4. Entries

Each commit becomes an `Entry`: type, scope, subject, breaking flag, and a
`State`. Conventional types map to Keep a Changelog groups (`feat → Added`,
`fix → Fixed`, `perf → Performance`, `refactor → Changed`, …). The file's own
vocabulary wins: a changelog that says `Features`/`Bug Fixes` gets those
headings, not `Added`/`Fixed`.

### 5. The plan

`release.Plan` holds: the file, its format, the absorbed `[Unreleased]`
content, the entries with their states, the version and how it was derived,
the date, the actions the user asked for, and the rendered result. Everything
downstream consumes it; nothing recomputes it.

### 6. Writing

The editor works on the file as a sequence of blocks (preamble, sections,
trailer) and splices the new section in at the computed insertion point.
Untouched bytes are copied verbatim, including CRLF and a missing final
newline. Writing is atomic (temp file in the same directory + rename).

`--commit` stages only the files chgl wrote, and refuses when unrelated changes
are already staged (or commits only our paths with `--commit --only`).
`--create-tag` tags after the commit. `--bump-version` optionally updates the
version source in the same commit.

## Design decisions

- **Plan-first.** The TUI and the headless path share one data structure, so
  "the TUI shows exactly what it will write" is true by construction.
- **Deterministic by default.** No model, no network, no guessing. The model
  is an optional final polish that may only rewrite titles and is validated
  against the deterministic result (same entries, same groups) or discarded.
- **Line-preserving editor.** Users' changelogs are hand-written prose.
  Re-rendering them from a data model reformats history and loses comments;
  splicing does not.
- **Refuse over guess.** Unknown file shape, non-Markdown changelog, existing
  section, unrelated staged changes: all refuse with a message that says how
  to proceed.
- **Tags are the release boundary.** The only machine-verifiable one. Headings
  without tags are reported, not trusted.
- **A TUI is the right UI here** — unlike `cmg`, the unit of work is a
  judgement (which commits, which version, which file) rather than one string.

## Distribution

`VERSION` holds the tool's version. `chgl` generates its own changelog from
its own commits, starting at its first release; the release workflow runs
`chgl` against the repository, builds static binaries, and publishes the
section as the release body.

## Known limitations

- Markdown changelogs only; `CHANGELOG.rst` and fragment systems are detected
  but refused.
- Newest tag must be semver-like; repositories that tag by date fall back to
  the whole history.
- Monorepos with several packages are not supported in v1 (`changelog.file`
  pins one).
- The model polish can rewrite wording but never decides content.
