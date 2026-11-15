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

echo "== formatting"
zig fmt --check build.zig src tests

echo "== end-to-end"
sh tests/e2e/run.sh

echo "== editor under a pty"
python3 tests/e2e/tui_pty.py "$root/zig-out/bin/chgl"
