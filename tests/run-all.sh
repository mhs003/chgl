#!/bin/sh
# Everything the CI should run: unit tests, end-to-end repositories, and the
# editor under a real pseudo-terminal.
#
#   sh tests/run-all.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "== unit"
zig build test --summary all

echo "== cross-compile every release target"
# The editor has a Windows code path that no test on this host would compile;
# building the matrix here is what caught it. Linux and macOS hosts can all
# cross-compile these, so run them everywhere rather than only in CI.
for target in x86_64-windows aarch64-macos x86_64-linux-musl aarch64-linux-musl x86_64-linux-gnu; do
    zig build -Dtarget=$target -Doptimize=ReleaseSafe
    echo "  ok   $target"
done

echo "== formatting"
zig fmt --check build.zig src tests

echo "== end-to-end"
sh tests/e2e/run.sh

echo "== editor under a pty"
python3 tests/e2e/tui_pty.py "$root/zig-out/bin/chgl"
