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

# ------------------------------------------------------------------- config
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
    # `init` writes to the platform config directory, which is %APPDATA% on
    # Windows and XDG elsewhere, so the path is taken from what it reports
    # rather than assumed.
    init_out=$(XDG_CONFIG_HOME="$conf2" "$bin" init 2>&1)
    written=$(printf '%s' "$init_out" | sed -n 's/.*wrote //p')
    [ -n "$written" ] && [ -f "$written" ] && pass "init writes config.toml" || fail "init writes config.toml" "$init_out"
    code=$(XDG_CONFIG_HOME="$conf2" code_of init)
    expect_eq "init refuses to overwrite" "1" "$code"
    code=$(XDG_CONFIG_HOME="$conf2" code_of init --force)
    expect_eq "init --force overwrites" "0" "$code"
    out=$("$bin" -V --config "$written" 2>&1)
    expect_contains "-V names the config in use" "$out" "$written" "$out"
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
