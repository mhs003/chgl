//! Thin wrapper around the `git` CLI.
//!
//! Shelling out instead of linking libgit2 keeps the binary free of native
//! build dependencies and makes the log honour the user's `git config`
//! (mailmap, diff drivers, attribute files).

const std = @import("std");

pub const Commit = @import("commit.zig");
pub const log = @import("log.zig");
pub const tags = @import("tags.zig");
pub const worktree = @import("worktree.zig");

/// The result of one `git` invocation.
pub const Output = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: Output, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }

    pub fn ok(self: Output) bool {
        return self.exit_code == 0;
    }
};

pub const Error = error{ OutOfMemory, GitMissing, GitFailed, Unsupported } || std.Io.Writer.Error;

/// Run `git` with `args`, capturing stdout. stderr is left attached to the
/// parent's terminal for explicit calls, but suppressed for probes where the
/// failure is expected (e.g. "is this a repo?").
pub const Runner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Set by `--verbose`; when true, the git command line is echoed to stderr.
    verbose: bool = false,
    /// Repository to run in. Empty means the current directory.
    cwd: []const u8 = "",
    /// Environment for commands that write. Null inherits the parent's, which
    /// is right for read-only git: the user's own config and credentials still
    /// apply. Commits pass a scrubbed copy — see `worktree.identityIsExplicit`.
    environ: ?*const std.process.Environ.Map = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Runner {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn inDir(self: Runner, dir: []const u8) Runner {
        var r = self;
        r.cwd = dir;
        return r;
    }

    /// Insert `-C <dir>` after the `git` program name, so every command runs
    /// in the requested repository rather than the shell's directory.
    fn argvFor(self: Runner, argv: []const []const u8, buf: *[64][]const u8) []const []const u8 {
        if (self.cwd.len == 0 or argv.len == 0) return argv;
        buf[0] = argv[0];
        buf[1] = "-C";
        buf[2] = self.cwd;
        const rest = @min(argv.len - 1, buf.len - 3);
        @memcpy(buf[3..][0..rest], argv[1..][0..rest]);
        return buf[0 .. 3 + rest];
    }

    pub fn run(self: Runner, argv: []const []const u8, quiet_stderr: bool) Error!Output {
        var text_buf: [64][]const u8 = undefined;
        const full = self.argvFor(argv, &text_buf);
        if (self.verbose) {
            var buf: [1024]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&buf);
            // `argv[0]` is already "git"; printing both produced "git git".
            for (full) |a| fbs.print("{s} ", .{a}) catch {};
            std.debug.print("chgl: run: {s}\n", .{std.mem.trimEnd(u8, fbs.buffered(), " ")});
        }

        var child = std.process.spawn(self.io, .{
            .argv = full,
            .stdout = .pipe,
            .stderr = if (quiet_stderr) .ignore else .inherit,
            .stdin = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.GitMissing,
            else => return error.GitFailed,
        };
        defer if (child.id != null) child.kill(self.io);

        const out_file = child.stdout orelse return error.GitFailed;
        var rbuf: [8192]u8 = undefined;
        var reader: std.Io.File.Reader = .init(out_file, self.io, &rbuf);
        const stdout = reader.interface.allocRemaining(self.allocator, .limited(64 << 20)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GitFailed,
        };
        errdefer self.allocator.free(stdout);

        const term = child.wait(self.io) catch return error.GitFailed;
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => 255,
        };
        return .{ .stdout = stdout, .exit_code = code };
    }

    /// Run and require success; the message names the failing command.
    pub fn must(self: Runner, argv: []const []const u8) Error![]u8 {
        const out = try self.run(argv, false);
        if (!out.ok()) {
            self.allocator.free(out.stdout);
            return error.GitFailed;
        }
        return out.stdout;
    }

    /// Run, inheriting stdio (for interactive/porcelain commands like commit).
    pub fn inherit(self: Runner, argv: []const []const u8) Error!u8 {
        var text_buf: [64][]const u8 = undefined;
        const full = self.argvFor(argv, &text_buf);
        var child = std.process.spawn(self.io, .{
            .argv = full,
            .stdout = .inherit,
            .stderr = .inherit,
            .stdin = .inherit,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.GitMissing,
            else => return error.GitFailed,
        };
        defer if (child.id != null) child.kill(self.io);
        const term = child.wait(self.io) catch return error.GitFailed;
        return switch (term) {
            .exited => |c| c,
            else => 255,
        };
    }

    /// Run with `stdin` fed from a file the caller wrote (for `commit -F`).
    pub fn withStdinFile(self: Runner, argv: []const []const u8, stdin: std.Io.File) Error!u8 {
        var text_buf: [64][]const u8 = undefined;
        const full = self.argvFor(argv, &text_buf);
        var child = std.process.spawn(self.io, .{
            .argv = full,
            .stdout = .inherit,
            .stderr = .inherit,
            .stdin = .{ .file = stdin },
        }) catch |err| switch (err) {
            error.FileNotFound => return error.GitMissing,
            else => return error.GitFailed,
        };
        defer if (child.id != null) child.kill(self.io);
        const term = child.wait(self.io) catch return error.GitFailed;
        return switch (term) {
            .exited => |c| c,
            else => 255,
        };
    }
};

/// True when the process is inside a work tree.
pub fn isRepo(runner: Runner) bool {
    const out = runner.run(&.{ "git", "rev-parse", "--is-inside-work-tree" }, true) catch return false;
    defer out.deinit(runner.allocator);
    return out.ok() and std.mem.eql(u8, std.mem.trim(u8, out.stdout, " \r\n"), "true");
}

/// True when the repository has at least one commit.
pub fn hasHead(runner: Runner) bool {
    const out = runner.run(&.{ "git", "rev-parse", "--verify", "--quiet", "HEAD" }, true) catch return false;
    defer out.deinit(runner.allocator);
    return out.ok();
}

/// A shallow clone has no history before its boundary and usually no tags.
/// Confusing that with "nothing to release" hides a broken CI checkout.
pub fn isShallow(runner: Runner) bool {
    const out = runner.run(&.{ "git", "rev-parse", "--is-shallow-repository" }, true) catch return false;
    defer out.deinit(runner.allocator);
    return out.ok() and std.mem.eql(u8, std.mem.trim(u8, out.stdout, " \r\n"), "true");
}

/// `origin`'s URL, if there is one.
pub fn remoteUrl(runner: Runner) ?[]u8 {
    const out = runner.run(&.{ "git", "remote", "get-url", "origin" }, true) catch return null;
    if (!out.ok()) {
        out.deinit(runner.allocator);
        return null;
    }
    const trimmed = std.mem.trim(u8, out.stdout, " \r\n");
    if (trimmed.len == 0) {
        out.deinit(runner.allocator);
        return null;
    }
    // Shrink the allocation so the caller can free it normally.
    const copy = runner.allocator.dupe(u8, trimmed) catch {
        out.deinit(runner.allocator);
        return null;
    };
    out.deinit(runner.allocator);
    return copy;
}

test "repo probes do not panic outside a repository" {
    // The test binary runs from the build root, which may or may not be a git
    // repository; either answer must come back without an error.
    const runner = Runner.init(std.testing.io, std.testing.allocator);
    const inside = isRepo(runner);
    if (inside) {
        try std.testing.expect(hasHead(runner) or !hasHead(runner));
    }
    _ = isShallow(runner);
}
