# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## What this project is

`chgl` is a changelog generator: it finds the changelog file a repository
already keeps, works out the unreleased commits from tags, and writes the next
release section into that file — after showing the user exactly what it will
write. It is a Zig binary with no runtime dependencies beyond `git`.

It is a sibling of `cmg` (commit messages), and deliberately not the same
tool: `cmg` refuses to be a TUI, `chgl`'s interactive mode *is* a TUI. The
rules that keep each of them good are different; do not copy `cmg`'s
"never a TUI" rule here.

## Hard rules

1. **The plan is the product.** Every action (`--dry-run`, `--write`,
   `--commit`, `--tag`, the TUI) renders and applies the *same* `release.Plan`.
   No second implementation for the TUI. If the TUI needs to decide something,
   a flag must be able to decide it too.
2. **stdout is a contract.** In headless mode stdout carries only the rendered
   section (or nothing). Diagnostics, warnings and progress go to stderr. The
   TUI draws on the controlling terminal, never on stdout, so a piped run can
   never receive escape codes. A run that wrote something ends with **one**
   summary line on stderr (`wrote <file>, <version>, committed, tagged`, only
   the parts that happened); `--quiet` removes it and every notice, but never
   `git`'s own output. No message may say "see above" for something that was
   not printed: on error the plan's notices are discarded.
3. **Exit codes matter.** `0` success, `1` error, `2` usage, `3` nothing to
   release, `4` would overwrite an existing release section (needs `--force`).
   `3` is deliberately the same meaning `cmg`'s release script uses, so a
   workflow can branch on it.
4. **Never write a file you do not understand.** The changelog editor is
   line-preserving: bytes outside the inserted region round-trip exactly. If
   the file cannot be parsed into a known shape, refuse and say why. Appending
   a section to an unrecognised file is how changelogs get corrupted.
   `chgl init` follows the same rule: it starts only a missing, empty, or
   title-only file, and refuses one with prose or in another format, leaving it
   byte-identical. It never reshapes somebody's text.
5. **Nothing is written without the user asking.** No `--write` means no writes;
   `--commit` and `--tag` are separate, explicit actions. The tool never pushes.
6. **Shell out to `git`.** No libgit2. The log format is one NUL-safe
   `-z`-terminated format in `git/log.zig`; do not invent a second one.
7. **stdout/stderr/TTY detection is explicit.** Do not assume a terminal: the
   TUI needs the controlling tty on both stdin and stdout, and refuses
   otherwise (so `chgl > notes.md` can never eat keystrokes).
8. **Secrets never go to stderr.** No API keys or full request bodies in error
   paths.

## Layout

```
src/main.zig              entry point; subcommand dispatch; actions
src/cli.zig               flag spec table, parser, generated --help
src/config*.zig           config discovery, parsing, validation, defaults
src/git/                  `git` subprocess wrappers (log, tags, status, remote)
src/detect.zig            changelog file detection and format inference
src/changelog.zig         parse / insert / round-trip of the file
src/release.zig           range -> entries -> Plan
src/version.zig           semver, bump rules, version sources
src/render.zig            section rendering (Keep a Changelog)
src/util/glob.zig         `--exclude` matching
tests/fixtures/           real-world changelogs used by round-trip tests
tests/e2e/                shell-driven end-to-end tests against temp repos
```

See `ARCHITECTURE.md` for how these fit together and `DOCS.md` for the user
reference.

## Target selection (do not regress this)

- The range is `last release tag..HEAD`: the newest tag that is semver-like
  **and** reachable from `HEAD`. Not `git describe`'s nearest tag (that picks
  `nightly` and `latest`), and never silently "all of history".
- **The file can run ahead of the tags.** CI often tags on push, so a release
  section written by `chgl --commit` has no tag for a while. When the newest
  version *in the file* is newer than every tag, that version is the boundary,
  and the bound is the `chore(release):` commit that wrote it — not `HEAD`.
  Work committed after that release is still unreleased and must be listed.
  Do not bound at `HEAD`: it silently swallows newer commits.
  Only `chore(release)` counts, never `chore(version)`: a later version bump
  also ends with the version and would hide the commits in between.
- No qualifying tag, or a shallow clone (`git rev-parse
  --is-shallow-repository`), is a loud notice: the range becomes the whole
  history capped by `changelog.max_commits`.
- Releasable commits are `feat`, `fix`, `perf`, `refactor`, `revert`, and
  anything with `!` or a `BREAKING CHANGE:` footer. Docs/chore/ci/test/style/
  build are kept (under their group) when a release happens, but do not cause
  one. No releasable commit in range → exit 3.
- Non-conventional commits are never dropped silently: they default to the
  `Ask` state in the TUI and to `skip` with a warning in headless mode.
  The mode is decided **before** the plan is built (`Request.editor`), because
  whether an editor opens is known at the call site, not inside `release.build`.
  Deciding it in the build, from a flag nobody set, made `Ask` unreachable
  while its unit test still passed: a test that passes the flag directly
  cannot see a caller that never does. Test this through `main`, not `build`.

## The changelog file (`[Unreleased]` policy)

The file's own `[Unreleased]` body is part of the release being cut:

1. empty/placeholder → ignored;
2. has content → **absorbed** into the new section (hand-written bullets move
   under the new version heading, headings the generator doesn't produce are
   carried over verbatim), leaving `[Unreleased]` empty for the next cycle;
3. a hand-written bullet identical to a generated one → the file's copy wins,
   the generated copy is dropped, warning on stderr;
4. `[changelog] unreleased = "absorb" | "leave"` exists for projects that use
   `[Unreleased]` as a scratchpad. The default is `absorb`.

Do not "insert below and leave it" as a shortcut: that is the duplicate-entry
bug this policy exists to prevent.

## Interactive mode (`--tui`)

The TUI is the only part allowed to hold the terminal, and it must give it
back on every exit path:

- alternate screen and raw mode are enabled only while it is up, and restored
  on normal exit, error, panic (a custom panic hook restores first), and
  `SIGINT`/`SIGTERM`/`SIGHUP`; `SIGTSTP` drops to cooked mode and
  `SIGCONT` restores;
- it requires a tty for both stdin and stdout, and refuses with an error
  otherwise;
- **every state has a word, not just a colour**: `Keep` / `Skip` / `Ask`, so
  `CHGL_NO_COLOR` (and monochrome terminals) stay fully legible;
- **the frame is plain ASCII, always.** No box drawing, no bullets, no arrows,
  no spinner. It must render identically in every terminal, every font, over
  SSH, and in a screenshot; there is no "fancy" variant to drift out of sync;
- the frame is drawn from a plain state struct and can be rendered into an
  offscreen buffer, so it is unit-testable without a TTY;
- keyboard only is a supported path: every action has a key and the footer
  shows it.

## Style

- Zig 0.16.0, pinned by `.zigversion` (CI reads it); `zig fmt` clean.
- Errors are concrete `error{}` sets with a `.msg` describing what to do next.
- Allocations are explicit: `gpa` for work, `init.arena` for process-lifetime
  strings. No global state.
- Comments explain *why*, not *what*. Keep them short.

## Testing

```sh
zig build test                 # unit tests, fast, no network, no git needed
sh tests/e2e/run.sh            # end-to-end against temp repos (needs git)
sh tests/run-all.sh            # all of the above, plus cross-compilation
```

`tests/run-all.sh` also cross-compiles every release target. That is not
decoration: a Windows-only `ioctl` and a test that faked a file handle with
`-1` both reached `master` because nothing on this host compiled the Windows
code path.

Add a test for every behaviour change; bug fixes get a regression test.
Round-trip tests over `tests/fixtures/` are the safety net for the editor —
a fixture is only "handled" if parsing and re-rendering it is byte-identical.
A bug that renders correctly but behaves wrongly (an apply screen that cancels)
has to be tested at the outcome level; a frame test cannot see it.

## Releases

`VERSION` is the source of truth for the tool's own version. Releases are cut
from Conventional Commits by `chgl` itself (`chgl --as "$NEXT" --write
--commit --create-tag`) — the tool maintains its own changelog from its first
release, which is also the end-to-end proof that it works.

The release workflow must not skip on the commit *message*: a hand-made
`chgl --create-tag` push also ends in a `chore(release)` commit, and skipping
it shipped `v0.7.0` with no binaries. It decides from the tag instead — an
untagged head cuts a release, a tagged head with a release does nothing, a
tagged head without one builds and publishes it.

CI that tags on push (rather than `chgl`) is normal: commit the release with
`chgl --write --commit`, and let CI tag `v$(cat VERSION)`. `chgl` must never
assume it is the only thing that creates tags.
