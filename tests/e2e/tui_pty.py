#!/usr/bin/env python3
"""Drive the real editor through a pseudo-terminal.

The unit tests prove the layout and the key handling; this proves the part they
cannot: that a real tty gets raw mode, that keystrokes drive the same state
machine, and that the terminal is handed back on the way out.

    python3 tests/e2e/tui_pty.py path/to/chgl

Exits non-zero on the first broken promise.
"""
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

CHANGELOG = """# Changelog

## [Unreleased]

## [0.7.3] - 2026-06-01

### Fixed

- **wait:** stop the menu drifting
"""

CARGO = '[package]\nname = "zap"\nversion = "0.7.3"\n'


def sh(cwd, *args):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


def make_repo(root):
    sh(root, "git", "init", "-q", "-b", "main")
    sh(root, "git", "config", "user.email", "t@example.com")
    sh(root, "git", "config", "user.name", "Test")
    sh(root, "git", "config", "commit.gpgsign", "false")
    sh(root, "git", "config", "tag.gpgsign", "false")
    with open(os.path.join(root, "CHANGELOG.md"), "w") as f:
        f.write(CHANGELOG)
    with open(os.path.join(root, "Cargo.toml"), "w") as f:
        f.write(CARGO)
    sh(root, "git", "add", "-A")
    sh(root, "git", "commit", "-qm", "chore(release): v0.7.3")
    sh(root, "git", "tag", "v0.7.3")
    for subject in (
        "feat(cli): add --dry-run",
        "fix(wait): stop the menu still drifting",
    ):
        sh(root, "git", "commit", "-q", "--allow-empty", "-m", subject)


def drive(binary, cwd, keys):
    """Run the editor under a pty, feeding `keys` with pauses."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ["TERM"] = "xterm-256color"
        os.execv(binary, [binary, "--tui", "--write"])

    out = b""

    def pump(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            out += chunk

    pump(1.5)
    for key in keys:
        os.write(fd, key)
        pump(0.4)
    pump(1.0)
    try:
        os.close(fd)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), out


def drive_default(binary, cwd):
    """Run with no flags at all, then quit."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ["TERM"] = "xterm-256color"
        os.execv(binary, [binary])

    out = b""
    deadline = time.time() + 5
    while time.time() < deadline and b"Keep" not in out:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
    try:
        os.write(fd, b"q")
    except OSError:
        pass
    time.sleep(0.5)
    while True:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status)
    except ChildProcessError:
        code = -1
    return code, out


def main():
    if len(sys.argv) != 2:
        print("usage: tui_pty.py <path-to-chgl>", file=sys.stderr)
        return 2
    binary = os.path.abspath(sys.argv[1])
    checks = []

    def check(name, ok, detail=""):
        checks.append((name, ok, detail))

    tmp = tempfile.mkdtemp()
    try:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        make_repo(repo)

        # space: skip the first entry. a: apply. y: confirm.
        code, screen = drive(binary, repo, [b" ", b"a", b"y"])
        check("exits 0 after applying", code == 0, f"exit {code}")
        check("draws an alternate screen", b"\x1b[?1049h" in screen)
        check("leaves the alternate screen", b"\x1b[?1049l" in screen)
        check("restores the cursor", b"\x1b[?25h" in screen)
        check("shows the detected file", b"CHANGELOG.md" in screen)
        check("shows the state words", b"Keep" in screen and b"Skip" in screen)

        with open(os.path.join(repo, "CHANGELOG.md")) as f:
            written = f.read()
        check("wrote the release section", "## [0.8.0]" in written, written[:80])
        check(
            "the skipped entry is absent",
            "add --dry-run" not in written,
            "skipped entry was written anyway",
        )
        check(
            "the kept entry is present",
            "stop the menu still drifting" in written,
        )

        # With no flags a person at a terminal gets the editor; a pipe gets
        # text. Both are documented, so both are checked here.
        repo_bare = os.path.join(tmp, "repo_bare")
        os.makedirs(repo_bare)
        make_repo(repo_bare)
        before = open(os.path.join(repo_bare, "CHANGELOG.md")).read()
        code, screen = drive_default(binary, repo_bare)
        check("no flags opens the editor when there is a terminal", b"Keep" in screen, repr(screen[-40:]))
        after = open(os.path.join(repo_bare, "CHANGELOG.md")).read()
        check("the default editor writes nothing on quit", before == after)

        # q must never write.
        repo2 = os.path.join(tmp, "repo2")
        os.makedirs(repo2)
        make_repo(repo2)
        before = open(os.path.join(repo2, "CHANGELOG.md")).read()
        code, _ = drive(binary, repo2, [b"q"])
        after = open(os.path.join(repo2, "CHANGELOG.md")).read()
        check("quitting writes nothing", before == after, "file changed")
        check("quitting exits non-zero", code != 0, f"exit {code}")

        # The editor must restore the terminal even when the process is killed.
        repo3 = os.path.join(tmp, "repo3")
        os.makedirs(repo3)
        make_repo(repo3)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(repo3)
            os.execv(binary, [binary, "--tui", "--write"])
        # Wait until the first frame is on screen: the handler is only
        # installed once the editor has taken the terminal.
        seen = b""
        deadline = time.time() + 5
        while time.time() < deadline and b"CHANGELOG.md" not in seen:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    seen += os.read(fd, 65536)
                except OSError:
                    break
        check("the editor came up under a pty", b"CHANGELOG.md" in seen, repr(seen[-40:]))
        os.kill(pid, 15)  # SIGTERM
        time.sleep(0.4)
        # Keep whatever arrived before the pty closes: EIO at the end of the
        # drain means "the child is gone", not "nothing was written".
        tail = b""
        while True:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                break
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            tail += chunk
        check(
            "a killed editor still restores the terminal",
            b"\x1b[?1049l" in tail or b"\x1b[?25h" in tail,
            f"tail={tail[-40:]!r}",
        )
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failed = 0
    for name, ok, detail in checks:
        if ok:
            print(f"  ok   {name}")
        else:
            failed += 1
            print(f"  FAIL {name}\n       {detail}")
    print(f"\n{len(checks) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
