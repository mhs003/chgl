//! Working-tree operations that change state: staging the file we wrote,
//! committing it, and tagging.
//!
//! Each one is deliberately a single `git` command with explicit paths, so the
//! tool can never sweep unrelated work into a release commit.

const std = @import("std");
const git = @import("root.zig");

pub const Error = error{ OutOfMemory, GitFailed, GitMissing, TagExists } || std.Io.Writer.Error;

/// Absolute path of the repository root.
pub fn root(runner: git.Runner) Error![]u8 {
    const out = runner.run(&.{ "git", "rev-parse", "--show-toplevel" }, false) catch |err| return mapErr(err);
    defer out.deinit(runner.allocator);
    if (!out.ok()) return error.GitFailed;
    return runner.allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \r\n"));
}

/// Staged paths, split from `-z` output. Owned by the caller.
pub fn stagedPaths(runner: git.Runner) Error![]const []const u8 {
    const out = runner.run(&.{ "git", "diff", "--cached", "--name-only", "-z" }, false) catch |err| return mapErr(err);
    defer out.deinit(runner.allocator);
    if (!out.ok()) return error.GitFailed;

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(runner.allocator);
    var it = std.mem.splitScalar(u8, out.stdout, 0);
    while (it.next()) |p| {
        if (p.len == 0) continue;
        try paths.append(runner.allocator, try runner.allocator.dupe(u8, p));
    }
    return paths.toOwnedSlice(runner.allocator);
}

/// Stage exactly these paths.
pub fn stage(runner: git.Runner, paths: []const []const u8) Error!void {
    if (paths.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(runner.allocator);
    try argv.append(runner.allocator, "git");
    try argv.append(runner.allocator, "add");
    try argv.append(runner.allocator, "--");
    for (paths) |p| try argv.append(runner.allocator, p);
    const out = runner.run(argv.items, false) catch |err| return mapErr(err);
    defer out.deinit(runner.allocator);
    if (!out.ok()) return error.GitFailed;
}

/// Commit with `message` (multi-line ok). With `only_paths`, the commit records
/// only those paths and leaves other staged work staged — `git commit --
/// <paths>` semantics, so a partially staged tree is not destroyed.
///
/// The message travels on stdin via `-F -`: argv limits and quoting are not a
/// concern, and nothing is left behind in the work tree if the commit fails.
pub fn commit(runner: git.Runner, message: []const u8, only_paths: ?[]const []const u8) Error!void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(runner.allocator);
    try argv.append(runner.allocator, "git");
    try argv.append(runner.allocator, "commit");
    try argv.append(runner.allocator, "--file");
    try argv.append(runner.allocator, "-");
    if (only_paths) |paths| {
        if (paths.len != 0) {
            try argv.append(runner.allocator, "--");
            for (paths) |p| try argv.append(runner.allocator, p);
        }
    }

    // `spawn` does not go through `Runner.run`'s `-C` rewrite.
    var cwd_buf: [3][]const u8 = undefined;
    var full: []const []const u8 = argv.items;
    if (runner.cwd.len != 0 and argv.items.len >= 1) {
        cwd_buf = .{ argv.items[0], "-C", runner.cwd };
        var joined: std.ArrayList([]const u8) = .empty;
        defer joined.deinit(runner.allocator);
        try joined.appendSlice(runner.allocator, &cwd_buf);
        try joined.appendSlice(runner.allocator, argv.items[1..]);
        full = try runner.allocator.dupe([]const u8, joined.items);
        defer runner.allocator.free(full);
        return spawnCommit(runner, full, message);
    }
    return spawnCommit(runner, full, message);
}

/// `git commit` prefers `GIT_AUTHOR_NAME` and friends over `user.name`, and
/// ordinary `chgl` users never set them. They run on CI runners that do.
///
/// If one is inherited there, the release commit is attributed to the account
/// whose login it names — and GitHub accounts that merely share the *tool's*
/// name exist. `gh pr create` on a GitHub runner set exactly these variables to
/// `chgl` while implementing this tool, and four releases were credited to that
/// unrelated account, creating a phantom contributor. Dropping them makes the
/// commit use the repository's configured identity everywhere.
const identity_overrides = [_][]const u8{
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL",
};

pub fn identityIsExplicit(key: []const u8) bool {
    for (identity_overrides) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// A copy of the parent environment without the identity overrides, so `git`
/// falls back to `user.name`/`user.email`.
pub fn scrubbedEnviron(gpa: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    for (parent.keys(), parent.values()) |k, v| {
        if (identityIsExplicit(k)) continue;
        try env.put(k, v);
    }
    return env;
}

fn spawnCommit(runner: git.Runner, argv: []const []const u8, message: []const u8) Error!void {
    var child = std.process.spawn(runner.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = runner.environ,
    }) catch |err| return mapErr(err);
    defer if (child.id != null) child.kill(runner.io);

    {
        const stdin = child.stdin orelse return error.GitFailed;
        var wbuf: [4096]u8 = undefined;
        var writer: std.Io.File.Writer = .init(stdin, runner.io, &wbuf);
        writer.interface.writeAll(message) catch return error.GitFailed;
        if (!std.mem.endsWith(u8, message, "\n")) writer.interface.writeAll("\n") catch return error.GitFailed;
        writer.interface.flush() catch return error.GitFailed;
        stdin.close(runner.io);
        child.stdin = null;
    }

    const term = child.wait(runner.io) catch return error.GitFailed;
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) return error.GitFailed;
}

/// Create an annotated tag at `HEAD`. An existing tag is `error.TagExists`,
/// never an overwrite: a tag is a published claim.
pub fn tag(runner: git.Runner, name: []const u8, message: []const u8) Error!void {
    const exists = runner.run(&.{ "git", "tag", "--list", name }, false) catch |err| return mapErr(err);
    defer exists.deinit(runner.allocator);
    if (!exists.ok()) return error.GitFailed;
    if (std.mem.trim(u8, exists.stdout, " \r\n").len != 0) return error.TagExists;

    const out = runner.run(&.{ "git", "tag", "-a", name, "-m", message }, false) catch |err| return mapErr(err);
    defer out.deinit(runner.allocator);
    if (!out.ok()) return error.GitFailed;
}

fn mapErr(err: anytype) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
}

test "the identity overrides are the four git ones" {
    try std.testing.expect(identityIsExplicit("GIT_AUTHOR_NAME"));
    try std.testing.expect(identityIsExplicit("GIT_AUTHOR_EMAIL"));
    try std.testing.expect(identityIsExplicit("GIT_COMMITTER_NAME"));
    try std.testing.expect(identityIsExplicit("GIT_COMMITTER_EMAIL"));
    // Everything else must survive: PATH, credential helpers, config overrides.
    try std.testing.expect(!identityIsExplicit("PATH"));
    try std.testing.expect(!identityIsExplicit("GIT_CONFIG_GLOBAL"));
    try std.testing.expect(!identityIsExplicit("GIT_EDITOR"));
    try std.testing.expect(!identityIsExplicit("git_author_name"));
}

test "scrubbing drops identity but keeps the rest of the environment" {
    const gpa = std.testing.allocator;
    var parent = std.process.Environ.Map.init(gpa);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    try parent.put("GIT_AUTHOR_NAME", "chgl");
    try parent.put("GIT_AUTHOR_EMAIL", "dev@chgl.invalid");
    try parent.put("GIT_COMMITTER_EMAIL", "someone@example.com");

    var env = try scrubbedEnviron(gpa, &parent);
    defer env.deinit();

    try std.testing.expect(env.get("GIT_AUTHOR_NAME") == null);
    try std.testing.expect(env.get("GIT_AUTHOR_EMAIL") == null);
    try std.testing.expect(env.get("GIT_COMMITTER_EMAIL") == null);
    try std.testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    try std.testing.expectEqual(@as(usize, 1), env.count());
}
