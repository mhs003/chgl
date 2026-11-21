#!/bin/sh
# End-to-end tests: real repositories in a temp dir, the real binary.
#
#   sh tests/e2e/run.sh            # everything
#   sh tests/e2e/run.sh write      # one group
#
# No network. Needs git; build first with `zig build`.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
bin="$root/zig-out/bin/chgl"
[ -x "$bin" ] || { echo "missing $bin; run 'zig build' first" >&2; exit 1; }

if [ -t 1 ]; then ok=$(printf '\033[32m'); bad=$(printf '\033[31m'); off=$(printf '\033[0m'); else ok=; bad=; off=; fi
passed=0
failed=0
group_filter=${1:-}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

t() { printf '%s\n' "  $1"; }

pass() { passed=$((passed + 1)); printf '  %sok%s   %s\n' "$ok" "$off" "$1"; }

fail() {
    failed=$((failed + 1))
    printf '  %sFAIL%s %s\n       %s\n' "$bad" "$off" "$1" "$2"
}

expect_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}

expect_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "missing [$3] in: $4" ;;
    esac
}

expect_not_contains() {
    case "$2" in
        *"$3"*) fail "$1" "unexpected [$3] in: $2" ;;
        *) pass "$1" ;;
    esac
}

want_group() {
    [ -n "$group_filter" ] && [ "$group_filter" != "$1" ] && return 1
    case "$group_filter" in "") ;; esac
    return 0
}

skip_group() {
    [ -n "$group_filter" ] && [ "$group_filter" != "$1" ]
}

new_repo() {
    dir="$tmp/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name "Test Author"
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config tag.gpgsign false
    echo "$dir"
}

commit() {
    git -C "$1" commit -q --allow-empty -m "$2"
}

# A changelog with an unreleased section and one release, plus a Cargo.toml.
seed_zap() {
    d=$(new_repo zap)
    printf '# Changelog\n\nAll notable changes.\n\n## [Unreleased]\n\n<!-- entries are added here -->\n\n## [0.7.3] - 2026-06-01\n\n### Fixed\n\n- **wait:** stop the menu drifting\n' > "$d/CHANGELOG.md"
    printf '[package]\nname = "zap"\nversion = "0.7.3"\nedition = "2021"\n' > "$d/Cargo.toml"
    git -C "$d" add -A
    git -C "$d" commit -qm "chore(release): v0.7.3"
    git -C "$d" tag v0.7.3
    commit "$d" "feat(cli): add --dry-run"
    commit "$d" "fix(wait): stop the menu still drifting"
    commit "$d" "docs: explain the config"
    commit "$d" "chore(release): v0.7.4"
    echo "$d"
}

run() { "$bin" "$@" 2>&1 || true; }

code_of() {
    set +e
    "$bin" "$@" >/dev/null 2>&1
    c=$?
    set -e
    printf '%s' "$c"
}

# Output plus the exit code, without `set -e` tripping on the non-zero case.
run_code() {
    set +e
    out=$("$bin" "$@" 2>&1)
    code=$?
    set -e
    printf '%s\nexit=%s' "$out" "$code"
}

# ---------------------------------------------------------------- detection
if ! skip_group detect; then
    t "detection"
    d=$(new_repo detect)
    printf '# Changelog\n\n## [1.0.0]\n\n- x\n' > "$d/CHANGELOG.md"
    out=$(run detect --repo "$d")
    expect_contains "finds root CHANGELOG.md" "$out" "CHANGELOG.md" "$out"

    d2=$(new_repo detect-docs)
    mkdir -p "$d2/docs"
    printf '# Changes\n\n## [1.0.0]\n\n- x\n' > "$d2/docs/CHANGES.md"
    out=$(run detect --repo "$d2")
    expect_contains "finds docs/CHANGES.md" "$out" "docs/CHANGES.md" "$out"

    d3=$(new_repo detect-rst)
    printf 'Changelog\n=========\n' > "$d3/CHANGELOG.rst"
    out=$(run detect --repo "$d3")
    expect_contains "names an rst changelog" "$out" "CHANGELOG.rst" "$out"
    expect_contains "refuses rst as not Markdown" "$out" "not Markdown" "$out"

    d4=$(new_repo detect-none)
    commit "$d4" "feat: x"
    out=$(run detect --repo "$d4")
    expect_contains "reports nothing found" "$out" "none found" "$out"

    d5=$(new_repo detect-frag)
    mkdir -p "$d5/.changeset"
    printf 'x\n' > "$d5/.changeset/one.md"
    out=$(run detect --repo "$d5")
    expect_contains "reports a fragment directory" "$out" ".changeset" "$out"
fi

# ------------------------------------------------------------------- ranges
if ! skip_group range; then
    t "range and version"
    d=$(seed_zap)
    out=$(run --repo "$d" --dry-run)
    expect_contains "derives 0.8.0 from feat since v0.7.3" "$out" "## [0.8.0]" "$out"
    expect_contains "lists the feature" "$out" "**cli:** add --dry-run" "$out"
    expect_contains "lists the fix" "$out" "**wait:** stop the menu still drifting" "$out"
    expect_not_contains "release commit is skipped" "$out" "chore(release)" "$out"
    expect_contains "docs commit is kept under Documentation" "$out" "### Documentation" "$out"

    out=$(run --repo "$d" --dry-run --as 9.9.9)
    expect_contains "--as overrides the derived version" "$out" "## [9.9.9]" "$out"

    out=$(run --repo "$d" --dry-run --exclude "fix(wait):*")
    expect_not_contains "exclude glob drops the fix entry" "$out" "still drifting" "$out"

    out=$(run --repo "$d" --dry-run --explain)
    expect_contains "--explain names each kept entry" "$out" "Keep [commits] feat(cli): add --dry-run" "$out"
    expect_contains "--explain gives a skip its reason" "$out" "release commit" "$out"

    out=$(run --repo "$d" --dry-run --date 2020-01-02)
    expect_contains "--date flows into the heading" "$out" "## [0.8.0] - 2020-01-02" "$out"

    d2=$(new_repo nothing)
    printf '# Changelog\n' > "$d2/CHANGELOG.md"
    commit "$d2" "docs: only docs"
    out=$(run_code --repo "$d2" --write)
    expect_contains "docs-only exits 3" "$out" "exit=3" "$out"
    out=$(run --repo "$d2" --dry-run)
    expect_contains "whole history notice without tags" "$out" "no release tag found" "$out"
fi

# ------------------------------------------------------------------ writing
if ! skip_group write; then
    t "writing"
    d=$(seed_zap)
    out=$(run --repo "$d" --write)
    expect_contains "reports the written file" "$out" "wrote CHANGELOG.md" "$out"

    file=$(cat "$d/CHANGELOG.md")
    expect_contains "section landed above the release" "$file" "## [0.8.0] - " "$file"
    expect_not_contains "hand-written release is untouched" "$file" "### Fixed\n\n- **wait:** stop the menu drifting" "" || true
    expect_contains "previous release still present" "$file" "## [0.7.3] - 2026-06-01" "$file"
    head -1 "$d/CHANGELOG.md" | grep -q '^# Changelog$' && pass "title kept" || fail "title kept" "$(head -3 "$d/CHANGELOG.md")"

    # Idempotency: the same release is never written twice.
    before=$(cat "$d/CHANGELOG.md")
    run_code --repo "$d" --write >/dev/null
    after=$(cat "$d/CHANGELOG.md")
    expect_eq "writing again leaves the file unchanged" "1" "$([ "$before" = "$after" ] && echo 1 || echo 0)"

    # Unreleased content is absorbed, not duplicated.
    d2=$(new_repo absorb)
    printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- planned: faster startup\n\n## [0.1.0] - 2026-01-01\n\n- first\n' > "$d2/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n' > "$d2/Cargo.toml"
    git -C "$d2" add -A && git -C "$d2" commit -qm "chore: init" && git -C "$d2" tag v0.1.0
    commit "$d2" "feat: cache the parser"
    run --repo "$d2" --write >/dev/null
    file=$(cat "$d2/CHANGELOG.md")
    expect_contains "hand-written bullet absorbed into the release" "$file" "- planned: faster startup" "$file"
    count=$(grep -c 'planned: faster startup' "$d2/CHANGELOG.md")
    expect_eq "absorbed bullet appears once" "1" "$count"
    expect_contains "unreleased heading is left empty for the next cycle" "$file" "## [Unreleased]" "$file"

    # Regression: an empty [Unreleased] *and* a footer. Clearing the section
    # used offsets from the pre-insert file, which truncated the new heading
    # and duplicated the [Unreleased] heading.
    d4=$(new_repo empty_unreleased_footer)
    printf '# Changelog\n\nIntro.\n\n## [Unreleased]\n\n[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD\n[0.1.0]: https://github.com/o/r/compare/v0.0.1...v0.1.0\n' > "$d4/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n' > "$d4/Cargo.toml"
    git -C "$d4" add -A && git -C "$d4" commit -qm "chore: init" && git -C "$d4" tag v0.1.0
    commit "$d4" "feat: y"
    run --repo "$d4" --write >/dev/null
    file=$(cat "$d4/CHANGELOG.md")
    expect_contains "the new heading is intact" "$file" "## [0.2.0] - " "$file"
    count=$(grep -c '^## \[Unreleased\]' "$d4/CHANGELOG.md")
    expect_eq "the unreleased heading appears once" "1" "$count"

    # Footer links are updated when the file uses them.
    d3=$(new_repo footer)
    printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- first\n\n[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD\n[0.1.0]: https://github.com/o/r/compare/v0.0.1...v0.1.0\n' > "$d3/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n' > "$d3/Cargo.toml"
    git -C "$d3" add -A && git -C "$d3" commit -qm "chore: init" && git -C "$d3" tag v0.1.0
    commit "$d3" "fix: a bug"
    run --repo "$d3" --write >/dev/null
    file=$(cat "$d3/CHANGELOG.md")
    expect_contains "footer points at the new tag" "$file" "[0.1.1]: https://github.com/o/r/compare/v0.1.0...v0.1.1" "$file"
    expect_contains "unreleased footer moves forward" "$file" "[Unreleased]: https://github.com/o/r/compare/v0.1.1...HEAD" "$file"
fi

# ------------------------------------------------------------------ git ops
if ! skip_group commit; then
    t "commit and tag"
    d=$(seed_zap)
    run --repo "$d" --write --commit >/dev/null
    subject=$(git -C "$d" log -1 --format=%s)
    expect_eq "release commit message" "chore(release): v0.8.0" "$subject"
    files=$(git -C "$d" show --name-only --format= HEAD)
    expect_eq "release commit touches only the changelog" "CHANGELOG.md" "$files"

    # Without a tag the range never closes, so the next run would rewrite the
    # same entries under a new heading. That has to be said out loud.
    d7=$(seed_zap)
    out=$(run --repo "$d7" --write --commit 2>&1)
    # One line per run, and --quiet silences even that.
    expect_contains "the summary names what happened" "$out" "committed" "$out"
    lines=$(printf '%s' "$out" | grep -c '^chgl:')
    expect_eq "one chgl line, not four" "1" "$lines"
    d8=$(seed_zap)
    out=$(run --repo "$d8" --write --commit --create-tag 2>&1)
    expect_contains "a tagged release says so on the same line" "$out" "committed, tagged" "$out"
    d11=$(seed_zap)
    out=$(run --repo "$d11" --write --commit --quiet 2>&1 | grep '^chgl:' || true)
    expect_eq "--quiet prints no chgl lines (git's own output stays)" "" "$out"

    # The file can run ahead of the tags when CI tags on push. A second run in
    # that window must not rewrite the same entries under a new heading.
    d9=$(seed_zap)
    run --repo "$d9" --write --commit >/dev/null 2>&1
    before=$(git -C "$d9" rev-parse HEAD:CHANGELOG.md)
    out=$(run_code --repo "$d9" --write)
    expect_contains "a release newer than every tag stops the next run" "$out" "exit=3" "$out"
    after=$(git -C "$d9" rev-parse HEAD:CHANGELOG.md)
    expect_eq "the changelog is left untouched" "$before" "$after"
    # [Unreleased], the release, and the previous one: no second 0.8.x.
    expect_eq "no second release section appears" "3" "$(grep -c '^## ' "$d9/CHANGELOG.md")"

    # But commits made *after* that untagged release are still unreleased and
    # must be released, not swallowed by the file boundary. The manifest has to
    # move on first: releasing the same commit set again would collide with the
    # section already in the file.
    d10=$(seed_zap)
    run --repo "$d10" --bump-version --write --commit >/dev/null 2>&1
    commit "$d10" "feat(web): a thing that happened after the release"
    out=$(run --repo "$d10" --dry-run)
    expect_contains "work after an untagged release is released" "$out" "a thing that happened after the release" "$out"
    expect_contains "the version moves past the untagged release" "$out" "## [0.9.0]" "$out"

    # A fresh repository for the tag path: the one above is already released.
    d2=$(seed_zap)
    out=$(run --repo "$d2" --write --commit --create-tag)
    git -C "$d2" tag --list 'v0.8.0' | grep -q . && pass "tag v0.8.0 created" || fail "tag v0.8.0 created" "$(git -C "$d2" tag)"
    subject=$(git -C "$d2" log -1 --format=%s)
    expect_eq "the tag commit is the release commit" "chore(release): v0.8.0" "$subject"

    # A manifest that lags the tags must not produce a version below them.
    d5=$(new_repo stale_manifest)
    printf '# Changelog\n\n## [0.2.0] - 2026-01-01\n\n- x\n' > "$d5/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n' > "$d5/Cargo.toml"
    git -C "$d5" add -A && git -C "$d5" commit -qm "chore: init" && git -C "$d5" tag v0.2.0
    commit "$d5" "fix: y"
    out=$(run --repo "$d5" --dry-run)
    expect_contains "a stale manifest still yields a new version" "$out" "## [0.2.1]" "$out"
    expect_contains "the mismatch is explained" "$out" "is tagged" "$out"

    # A tag already sitting on HEAD means there is nothing in range; the run
    # says so instead of writing an empty section.
    d3=$(seed_zap)
    git -C "$d3" tag v0.8.0
    out=$(run_code --repo "$d3" --write --create-tag)
    expect_contains "a tag on HEAD leaves nothing to release" "$out" "exit=3" "$out"

    # Regression: CI runners export GIT_AUTHOR_* and `git` prefers them over
    # user.name, so a release could be attributed to whichever GitHub account
    # an inherited address happens to belong to. Seen in production: four
    # releases were credited to a stranger named after this very tool.
    d6=$(seed_zap)
    GIT_AUTHOR_NAME="chgl" GIT_AUTHOR_EMAIL="dev@chgl.invalid" \
        GIT_COMMITTER_NAME="chgl" GIT_COMMITTER_EMAIL="dev@chgl.invalid" \
        "$bin" --repo "$d6" --write --commit >/dev/null 2>&1
    who=$(git -C "$d6" log -1 --format='%an <%ae>')
    expect_eq "an inherited GIT_AUTHOR is ignored" "Test Author <t@example.com>" "$who"
    who=$(git -C "$d6" log -1 --format='%cn <%ce>')
    expect_eq "an inherited GIT_COMMITTER is ignored" "Test Author <t@example.com>" "$who"
fi

# ----------------------------------------------------------- bump version
if ! skip_group bump; then
    t "version write-back"
    d=$(new_repo bump)
    printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- first\n' > "$d/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n\n[dependencies]\nserde = { version = "1" }\n' > "$d/Cargo.toml"
    git -C "$d" add -A && git -C "$d" commit -qm "chore: init" && git -C "$d" tag v0.1.0
    commit "$d" "feat: speed"

    # Off by default: a separate bump commit is a legitimate workflow.
    run --repo "$d" --write --commit >/dev/null
    grep -q 'version = "0.1.0"' "$d/Cargo.toml" && pass "Cargo.toml untouched without --bump-version" || fail "Cargo.toml untouched without --bump-version" "$(cat "$d/Cargo.toml")"

    d2=$(new_repo bump2)
    printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- first\n' > "$d2/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n\n[dependencies]\nserde = { version = "1" }\n' > "$d2/Cargo.toml"
    git -C "$d2" add -A && git -C "$d2" commit -qm "chore: init" && git -C "$d2" tag v0.1.0
    commit "$d2" "feat: speed"
    run --repo "$d2" --write --commit --bump-version >/dev/null
    grep -q 'version = "0.2.0"' "$d2/Cargo.toml" && pass "--bump-version updates the package version" || fail "--bump-version updates the package version" "$(cat "$d2/Cargo.toml")"
    grep -q 'serde = { version = "1" }' "$d2/Cargo.toml" && pass "dependency versions are not touched" || fail "dependency versions are not touched" "$(cat "$d2/Cargo.toml")"
    files=$(git -C "$d2" show --name-only --format= HEAD | sort | tr '\n' ' ')
    expect_contains "the release commit includes the changelog" "$files" "CHANGELOG.md" "$files"
    expect_contains "the release commit includes the manifest" "$files" "Cargo.toml" "$files"
fi

# ------------------------------------------------------------------- editor
if ! skip_group tui; then
    t "interactive editor"
    d=$(seed_zap)
    out=$(run --repo "$d" --dump-frame)
    expect_contains "the editor shows the detected file" "$out" "CHANGELOG.md" "$out"
    expect_contains "it names every state in words" "$out" "Keep" "$out"
    expect_contains "it shows the range and version" "$out" "0.7.3 -> 0.8.0" "$out"
    expect_contains "skipped entries carry a reason" "$out" "release commit" "$out"
    expect_contains "the footer lists the keys" "$out" "preview" "$out"

    out=$(run --repo "$d" --dump-frame --frame preview)
    expect_contains "preview shows the new heading" "$out" "## [0.8.0]" "$out"
    expect_contains "preview shows the first line of the file" "$out" "# Changelog" "$out"

    # The frame is plain ASCII by design: no box-drawing, every glyph < 0x80.
    nonascii=$(printf '%s' "$out" | LC_ALL=C grep -c '[^[:print:][:space:]]' || true)
    expect_eq "the frame has no non-ASCII bytes" "0" "$nonascii"

    before=$(cat "$d/CHANGELOG.md")
    run --repo "$d" --dump-frame >/dev/null
    after=$(cat "$d/CHANGELOG.md")
    expect_eq "the editor writes nothing on its own" "1" "$([ "$before" = "$after" ] && echo 1 || echo 0)"

    # A pipe is never a terminal, so the default must be plain text: this is the
    # half of "editor at a terminal, text in a pipe" that a script can check.
    out=$(run --repo "$d")
    expect_contains "a piped run prints text, not escape codes" "$out" "## [0.8.0]" "$out"
    esc=$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" || true)
    expect_eq "a piped run never emits escape codes" "0" "$esc"

    # Without a terminal, --tui must fall back rather than hang.
    out=$(run_code --repo "$d" --tui)
    expect_contains "no terminal falls back instead of hanging" "$out" "## [0.8.0]" "$out"
fi

# ------------------------------------------------- non-conventional commits
# A commit that is not a Conventional Commit is the user's to decide. The
# editor must offer it as Ask; headless must skip it with a warning. Ask was
# unreachable once, because the decision was made before the editor was known.
if [ -z "${ONLY:-}" ] || [ "$ONLY" = "ask" ]; then
    t "unconventional commits, in the editor and in a pipe"
    d=$(seed_zap)
    ( cd "$d" && git commit -q --allow-empty -m "just some words" )

    out=$(run --repo "$d" --dump-frame)
    expect_contains "the editor offers it as Ask" "$out" "1 ask" "$out"
    expect_contains "and names the state on the row" "$out" "Ask " "$out"

    out=$(run_code --repo "$d" --dry-run)
    expect_contains "a pipe skips it, and says so" "$out" "were skipped" "$out"

    out=$(run_code --repo "$d" --dry-run --include-unconventional)
    expect_contains "--include-unconventional lists it" "$out" "just some words" "$out"
fi

# ------------------------------------------------------------------- config
if [ -z "${ONLY:-}" ] || [ "$ONLY" = "config" ]; then
    t "a repository can carry its own config"
    # Without this, a project whose version lives somewhere unusual needed a
    # flag on every run, and the only place to set it was the machine-wide
    # file — which then applied to every other repository too.
    d="$tmp/repoconf"
    mkdir -p "$d"
    ( cd "$d" && git init -q -b main && git config user.email a@b && git config user.name A )
    printf '# Changelog\n\n## [1.0.0]\n\n- x\n' > "$d/CHANGELOG.md"
    printf '1.0.0\n' > "$d/VERSION"
    # A frontend manifest that would win the auto-detection order.
    printf '{"name":"ui","version":"9.4.0","private":true}\n' > "$d/package.json"
    git -C "$d" add -A && git -C "$d" commit -qm "chore: init" && git -C "$d" tag v1.0.0
    commit "$d" "feat(cli): keep me"

    out=$("$bin" --repo "$d" --dry-run 2>&1 || true)
    expect_contains "package.json wins auto-detection by default" "$out" "9.5.0" "$out"

    printf '[version]\nsource = "file"\npath = "VERSION"\n' > "$d/.chgl.toml"
    out=$("$bin" --repo "$d" --dry-run 2>&1 || true)
    expect_contains "a repo config picks the version source" "$out" "1.1.0" "$out"

    # Found from anywhere inside the repository, not just its root.
    mkdir -p "$d/sub/dir"
    out=$(cd "$d/sub/dir" && "$bin" --dry-run 2>&1 || true)
    expect_contains "it is found from a subdirectory" "$out" "1.1.0" "$out"

    # A machine-wide file must not override the repository's own.
    conf3="$tmp/conf3/chgl"
    mkdir -p "$conf3"
    printf '[version]\nsource = "npm"\n' > "$conf3/config.toml"
    out=$(cd "$d" && XDG_CONFIG_HOME="$tmp/conf3" "$bin" --dry-run 2>&1 || true)
    expect_contains "the repo config beats the machine-wide one" "$out" "1.1.0" "$out"

    # An explicit --config still wins over both.
    printf '[version]\nsource = "npm"\n' > "$tmp/explicit.toml"
    out=$(cd "$d" && "$bin" --config "$tmp/explicit.toml" --dry-run 2>&1 || true)
    expect_contains "--config beats a repo config" "$out" "9.5.0" "$out"
fi

if ! skip_group config; then
    t "configuration"
    d=$(new_repo cfg)
    printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- x\n' > "$d/CHANGELOG.md"
    printf '[package]\nname = "z"\nversion = "0.1.0"\n' > "$d/Cargo.toml"
    git -C "$d" add -A && git -C "$d" commit -qm "chore: init" && git -C "$d" tag v0.1.0
    commit "$d" "feat(cli): keep me"
    commit "$d" "fix(api): drop me"

    conf="$tmp/conf"
    mkdir -p "$conf/chgl"
    printf '[changelog]\nexclude = ["fix(api):*"]\n' > "$conf/chgl/config.toml"
    out=$(CHGL_CONFIG="$conf/chgl/config.toml" "$bin" --repo "$d" --dry-run 2>&1 || true)
    expect_contains "a config exclude applies" "$out" "keep me" "$out"
    expect_not_contains "the excluded entry is gone" "$out" "drop me" "$out"

    printf '[changelog]\nmax_commit = 5\n' > "$conf/chgl/config.toml"
    out=$(CHGL_CONFIG="$conf/chgl/config.toml" "$bin" --repo "$d" --dry-run 2>&1 || true)
    expect_contains "a typo in the config is an error" "$out" "unknown key" "$out"

    printf '[changelog]\nunreleased = "sideways"\n' > "$conf/chgl/config.toml"
    out=$(CHGL_CONFIG="$conf/chgl/config.toml" "$bin" --repo "$d" --dry-run 2>&1 || true)
    expect_contains "an invalid enum is an error" "$out" "invalid value" "$out"

    # init writes a usable config, and refuses to clobber one.
    conf2="$tmp/conf2"
    mkdir -p "$conf2"
    # `config init` writes to the platform config directory, which is %APPDATA%
    # on Windows and XDG elsewhere; --config names it outright.
    init_out=$(XDG_CONFIG_HOME="$conf2" "$bin" config init 2>&1)
    written=$(printf '%s' "$init_out" | sed -n 's/.*wrote //p')
    [ -n "$written" ] && [ -f "$written" ] && pass "config init writes config.toml" || fail "config init writes config.toml" "$init_out"
    code=$(XDG_CONFIG_HOME="$conf2" code_of config init)
    expect_eq "config init refuses to overwrite" "1" "$code"
    code=$(XDG_CONFIG_HOME="$conf2" code_of config init --force)
    expect_eq "config init --force overwrites" "0" "$code"
    out=$("$bin" -V --config "$written" 2>&1)
    expect_contains "-V names the config in use" "$out" "$written" "$out"

    # `config init --config` writes exactly where it is told.
    explicit="$conf2/explicit/nested/config.toml"
    "$bin" config init --config "$explicit" >/dev/null 2>&1
    [ -f "$explicit" ] && pass "config init --config writes that path" || fail "config init --config writes that path" "missing $explicit"
fi

# ---------------------------------------------------------------- init (file)
if ! skip_group init; then
    t "creating the changelog"
    d=$(new_repo init_missing)
    out=$(run_code --repo "$d" init)
    expect_contains "a missing changelog is created" "$out" "exit=0" "$out"
    [ -f "$d/CHANGELOG.md" ] && pass "CHANGELOG.md exists" || fail "CHANGELOG.md exists" "missing"
    grep -q '## \[Unreleased\]' "$d/CHANGELOG.md" && pass "it has an Unreleased heading" || fail "it has an Unreleased heading" "$(cat "$d/CHANGELOG.md")"

    out=$(run_code --repo "$d" init)
    expect_contains "running init again is a no-op" "$out" "exit=0" "$out"
    expect_contains "and says the file is ready" "$out" "is ready" "$out"

    # An empty file is started, not rejected as "not Markdown".
    d2=$(new_repo init_empty)
    : > "$d2/CHANGELOG.md"
    out=$(run_code --repo "$d2" init)
    expect_contains "an empty changelog is started" "$out" "exit=0" "$out"
    grep -q '## \[Unreleased\]' "$d2/CHANGELOG.md" && pass "the skeleton landed" || fail "the skeleton landed" "$(cat "$d2/CHANGELOG.md")"

    # A bare title is kept; the skeleton is appended under it.
    d3=$(new_repo init_title)
    printf '# My Project\n' > "$d3/CHANGELOG.md"
    out=$(run_code --repo "$d3" init)
    expect_contains "a title-only changelog is started" "$out" "exit=0" "$out"
    head -1 "$d3/CHANGELOG.md" | grep -q '# My Project' && pass "the user's title is kept" || fail "the user's title is kept" "$(head -1 "$d3/CHANGELOG.md")"
    grep -q '## \[Unreleased\]' "$d3/CHANGELOG.md" && pass "and Unreleased was added" || fail "and Unreleased was added" "$(cat "$d3/CHANGELOG.md")"

    # Real content is never overwritten, or changelogs get corrupted.
    d4=$(new_repo init_content)
    printf '# Changelog\n\nWe ship often. Notes are kept by hand below.\n\n- did a thing\n' > "$d4/CHANGELOG.md"
    cp "$d4/CHANGELOG.md" "$tmp/before.md"
    out=$(run_code --repo "$d4" init)
    expect_contains "a file with prose is refused" "$out" "exit=1" "$out"
    cmp -s "$d4/CHANGELOG.md" "$tmp/before.md" && pass "and is left byte-identical" || fail "and is left byte-identical" "file changed"

    # A changelog in another format is a deliberate choice.
    d5=$(new_repo init_rst)
    printf 'Release 1.0\n===========\n' > "$d5/CHANGELOG.rst"
    out=$(run_code --repo "$d5" init)
    expect_contains "an rst changelog is refused" "$out" "exit=1" "$out"
    [ -f "$d5/CHANGELOG.md" ] && fail "no Markdown file is shadowing it" "CHANGELOG.md appeared" || pass "no Markdown file is shadowing it"

    # --file names the target, including a directory that does not exist yet.
    d6=$(new_repo init_file)
    out=$(run_code --repo "$d6" init --file docs/HISTORY.md)
    expect_contains "init --file creates the named path" "$out" "exit=0" "$out"
    [ -f "$d6/docs/HISTORY.md" ] && pass "the parent directory was created" || fail "the parent directory was created" "missing"

    # A release already in the file means there is nothing to create.
    d7=$(new_repo init_released)
    printf '# Changelog\n\n## [1.2.3] - 2026-01-01\n\n- x\n' > "$d7/CHANGELOG.md"
    out=$(run_code --repo "$d7" init)
    expect_contains "a changelog with releases is left alone" "$out" "exit=0" "$out"
fi

# --------------------------------------------------------------- exit codes
if ! skip_group exit; then
    t "exit codes"
    expect_eq "unknown option is 2" "2" "$(code_of --nope)"
    d=$(new_repo ec)
    commit "$d" "feat: x"
    expect_eq "detect without a changelog is 0" "0" "$(code_of detect --repo "$d")"
    expect_eq "no changelog is 1" "1" "$(code_of --repo "$d" --dry-run)"
    expect_eq "commit without write is 2" "2" "$(code_of --commit)"
    expect_eq "tui and no-tui conflict is 2" "2" "$(code_of --tui --no-tui)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
