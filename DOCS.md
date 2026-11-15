# chgl

`chgl` finds the changelog a repository already keeps, works out what has
changed since the last release tag, and writes the next release section — after
showing you exactly what it will write.

```sh
chgl               # review, then apply
chgl --dry-run     # print the section; touch nothing
```

Everything is one binary with no runtime dependencies beyond `git`. The model
is optional and only rewords; without it the tool is fully offline.

- [Synopsis](#synopsis)
- [Commands](#commands)
- [Options](#options)
- [How the changelog is found](#how-the-changelog-is-found)
- [How the range is chosen](#how-the-range-is-chosen)
- [How the version is chosen](#how-the-version-is-chosen)
- [The `[Unreleased]` section](#the-unreleased-section)
- [Interactive mode](#interactive-mode)
- [Configuration](#configuration)
- [Exit codes](#exit-codes)
- [Examples](#examples)

## Synopsis

```
chgl [COMMAND] [OPTIONS]
```

Without a command, `chgl` builds the next release section and either opens the
editor (`--tui`, or by default when both stdin and stdout are terminals) or
prints the section to stdout.

## Commands

### `chgl init`

Writes an example `config.toml` to the platform config directory.

| Flag | Meaning |
| --- | --- |
| `-f`, `--force` | Overwrite an existing file. |

### `chgl detect`

Reports which file is the changelog, why it was chosen, and whether `chgl` can
write to it.

```
$ chgl detect
repository: /home/you/zap
changelog: CHANGELOG.md  (known changelog name, Keep a Changelog)
candidates:
   100  CHANGELOG.md  (known changelog name)
    90  docs/CHANGES.md  (known changelog name)
```

Non-Markdown changelogs (`CHANGELOG.rst`, a plain-text `CHANGELOG`,
`debian/changelog`) and fragment systems (`.changeset/`, `changelog.d/`) are
named but not written: guessing at their structure breaks them.

### `chgl log`

Prints the section for the current range without applying anything and
without a model. The quickest way to check how commits will be grouped.

## Options

### The file and the range

| Option | Meaning |
| --- | --- |
| `--file <PATH>` | Use this changelog instead of detecting one. |
| `--repo <DIR>` | Run in this repository instead of the current directory. |
| `--since <REV>` | Start of the range. Default: the latest release tag. |
| `--path-to <REV>` | End of the range. Default: `HEAD`. |
| `--all` | Use the whole history, capped by `changelog.max_commits`. |
| `--tag-prefix <P>` | Tag prefix such as `v`. Default: inferred from tags. |

### The version and the section

| Option | Meaning |
| --- | --- |
| `--as <VERSION>` | Release version to write. Default: derived (§ below). |
| `--date <YYYY-MM-DD>` | Section date. Default: today, UTC. |

### What is listed

| Option | Meaning |
| --- | --- |
| `--exclude <GLOB>` | Skip subjects matching this glob. Repeatable. |
| `--parse-merges` | List merge commits by their subject instead of skipping them. |
| `--include-unconventional` | List commits that are not Conventional Commits. |

Globs, not regexes: `--exclude 'chore(release):*'`, `--exclude 'Merge *'`.
Supported: `*`, `?`, `[a-z]`, `[!a-z]`, and `{feat,fix}`.

### What is done

| Option | Meaning |
| --- | --- |
| (none) | Print the section to stdout. |
| `--write` | Insert the section into the file. |
| `--dry-run` | Print the section and never write, even with other flags. |
| `--commit` | Commit after writing (needs `--write`). |
| `--commit-only` | Record only the changelog in that commit, leaving other staged work staged. |
| `--bump-version` | Also set the version in `Cargo.toml` / `package.json` / `pyproject.toml` / `VERSION`. |
| `--create-tag` | Tag the release after committing. |
| `--force` | Write the section even if one with that version exists. |
| `-i`, `--tui` | Open the interactive editor. |
| `--no-tui` | Never open the editor. |
| `--dump-frame` | Print one editor frame as text and exit. |
| `--frame <list\|preview\|help\|confirm>` | Which frame `--dump-frame` prints. |

### Everything else

| Option | Meaning |
| --- | --- |
| `--config <PATH>` | Config file, instead of `$CHGL_CONFIG` or the default. |
| `-q`, `--quiet` | Suppress `chgl`'s notices and summary on stderr (git's own output is untouched). |
| `-v`, `--verbose` | Print diagnostics, including each `git` command. |
| `-V`, `--version` | Print the version. |
| `-h`, `--help` | Print help. |

## How the changelog is found

Candidates are scored, and the highest wins:

| Score | Signal |
| --- | --- |
| 100 | `CHANGELOG.md`, `CHANGES.md`, `HISTORY.md`, `NEWS.md`, `RELEASE_NOTES.md`, `NOTES.md` in the repository root |
| 90 | The same names in `docs/`, `doc/`, `.github/`, `Documentation/` |
| 80 | `changelog` (e.g. `debian/changelog`), `CHANGELOG.rst` — detected, refused |
| 75 | A fragment directory: `.changeset/`, `changelog.d/`, `news/`, `changes/` |
| 70 | Any other Markdown file that parses as a changelog |

A Markdown file that merely mentions "changelog" is not a candidate. A file
with only a `# Changelog` title counts: that is a changelog you have started.

`--file` skips detection entirely.

## How the range is chosen

The range is **the latest release tag .. `HEAD`**, where "release tag" means:

- a tag that parses as a version under the inferred prefix (`v1.2.3` or
  `1.2.3`), and
- is reachable from `HEAD`, and
- is not a prerelease.

`latest`, `nightly` and `v2.0.0-rc.1` are therefore never the boundary. The
newest qualifying tag wins, so a stray older tag cannot shorten the range.

With no qualifying tag — a fresh repository, or a shallow clone in CI — the
range becomes the whole history, capped by `changelog.max_commits` (200), and
`chgl` says so.

Commits are classified by their Conventional Commits type:

| Commit | Section |
| --- | --- |
| `feat` | Added |
| `fix` | Fixed |
| `perf` | Performance |
| `refactor` | Changed |
| `docs` | Documentation |
| `build` / `ci` / `test` / `style` / `chore` | Build / CI / Tests / Styles / Maintenance |
| `!` or a `BREAKING CHANGE:` footer | Breaking Changes (and its own section) |
| anything else | Other, or skipped — see below |

If the file already says `Features` and `Bug Fixes`, new entries use those
words instead of `Added` and `Fixed`.

Release commits (`chore(release): …`) are skipped. Merge commits are skipped
unless `--parse-merges`. Commits that are not Conventional Commits are skipped
with a notice; in the editor they appear as **Ask**, so the decision is yours.

### What justifies a release

`feat`, `fix`, `perf`, `refactor`, `revert`, and any breaking change. Docs-only
or chore-only ranges produce nothing and exit `3`, the same rule the reference
`cmg` release script uses.

## How the version is chosen

The current version is read from the first of:

1. `[package] version` in `Cargo.toml`
2. `"version"` in `package.json`
3. `[project]` or `[tool.poetry]` version in `pyproject.toml`
4. `VERSION`

Then:

- any breaking change → major (minor while the major is `0`)
- else any `feat` → minor
- else → patch

No source at all means no invented version: the heading is `## [Unreleased]`
and you are told to pass `--as`. `--as` always wins.

`--bump-version` writes the new version back into that file, changing that
value and nothing else. It is off by default, because bumping in a separate
commit is a normal workflow.

## The `[Unreleased]` section

Hand-written entries under `[Unreleased]` are part of the release being cut:

- an empty section (or one holding only an HTML comment) is ignored;
- a section with bullets is **absorbed**: those bullets move into the new
  release with their wording untouched, and `[Unreleased]` is left empty for
  the next cycle;
- a hand-written bullet identical to a generated one is listed once, the
  file's copy winning;
- their headings use the file's own words.

If you use `[Unreleased]` as a scratchpad, set `changelog.unreleased = "leave"`.

## Interactive mode

`chgl` opens the editor when stdin and stdout are terminals. `chgl -i` forces
it; `chgl --no-tui` never opens it, and a redirected run never does.

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
+------------------------------------------------------------------------------------+
```

Every entry has a **word**, not just a colour: `Keep`, `Skip`, `Ask`, with the
reason for a skip on the right. The frame is plain ASCII, so it looks the same
in every terminal and every font.

| Key | Effect |
| --- | --- |
| `j` `k`, arrows | Move between entries |
| `space`, `tab` | Keep or skip the selected entry |
| `g` / `G`, `Home` / `End` | First / last entry |
| `p` | Preview the exact file that will be written |
| `a` | Apply: write, then commit and tag as you asked |
| `?` | The key reference |
| `q`, `Esc`, `Ctrl-C` | Quit without writing anything |

Applying always asks first (`y`/`n`), and nothing is written until you answer.
The terminal is restored on every exit path: normal quit, error, `Ctrl-C`,
`SIGTERM`, `SIGHUP`, and a panic. Locking the screen or killing the terminal
does not leave your shell in raw mode.

`chgl --dump-frame` prints one frame as plain text, which is how the layout is
tested without a terminal.

## Configuration

TOML, or JSON with the same keys. Every key is optional; an unknown key is an
error, so a typo like `max_commit` fails instead of being ignored.

Lookup order: `--config`, `$CHGL_CONFIG`, then the platform directory —
`%APPDATA%\chgl` on Windows, otherwise `$XDG_CONFIG_HOME/chgl` or
`~/.config/chgl`, holding `config.toml` or `config.json`.

```toml
[changelog]
file = "auto"            # or a path
tag_prefix = "auto"      # inferred from tags
max_commits = 200        # used when there is no release tag
unreleased = "absorb"    # or "leave"
exclude = []             # globs, e.g. ["chore(release):*", "Merge *"]

[version]
source = "auto"          # auto | cargo | npm | pyproject | file | none
path = ""                # for source = "file"
bump = "auto"            # auto | major | minor | patch
write_back = false       # same as --bump-version

[output]
commit_links = false     # append a commit link to every entry
issue_links = true       # link #123 when the remote is known

[polish]
enabled = false          # off: nothing leaves your machine
max_entries = 40
extra_instructions = ""

[ui]
theme = "auto"           # auto | dark | light | mono

# Only needed when [polish] is on. Any OpenAI-compatible endpoint.
# [provider]
# base_url = "https://api.openai.com/v1"
# model = "gpt-4o-mini"
# api_key_env = "OPENAI_API_KEY"
# timeout_secs = 60
```

### Environment

| Variable | Meaning |
| --- | --- |
| `CHGL_CONFIG` | Config file path. |
| `XDG_CONFIG_HOME`, `HOME`, `APPDATA`, `USERPROFILE` | Where the config directory is. |
| `NO_COLOR` | Disable colour. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Failure: no repository, no changelog, a git error, or the editor was cancelled. |
| `2` | Usage error. |
| `3` | Nothing to release. |
| `4` | That release section already exists (use `--force`). |

A cancelled editor writes nothing and exits `1`.

## Examples

```sh
# See what it would write, without changing anything
chgl --dry-run

# Review and apply in the editor
chgl -i

# Scripted release: write, commit, tag, and bump the manifest
chgl --as 1.0.0 --write --bump-version --commit --create-tag

# Notes for a GitHub release, no file touched
chgl --dry-run > release-notes.md

# Keep the release bot's commits out
chgl --exclude 'chore(release):*' --dry-run

# Check how a range will be grouped
chgl log --since v0.6.0
```
