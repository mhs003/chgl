//! Tag selection.
//!
//! The release boundary is a *version*, not "whatever tag is nearest". `git
//! describe` answers "nearest annotated tag", which in a real repository can be
//! `nightly`, `latest`, or a prerelease that sorts after the release it
//! precedes. So tags are listed, parsed, filtered to versions, and the highest
//! one reachable from `HEAD` wins.

const std = @import("std");
const git = @import("root.zig");
const semver = @import("../version/semver.zig");

pub const Tag = struct {
    name: []const u8,
    /// The commit the tag points at (dereferenced for annotated tags).
    commit: []const u8,
    version: semver.Semver,
};

pub const Selection = struct {
    /// Highest reachable version tag, or null when the repo has none.
    latest: ?Tag = null,
    /// The tag style inferred from all tags in the repo.
    style: semver.TagStyle,
    /// Tag names that look like versions but were not reachable from HEAD.
    reachable: []const Tag = &.{},
};

pub const Error = error{ OutOfMemory, GitFailed, GitMissing };

/// Every tag as `name\0commit\0`, with annotated tags peeled to their commit.
pub fn listAll(runner: git.Runner) Error![]Tag {
    const out = runner.run(&.{ "git", "for-each-ref", "--format=%(refname:short)%1f%(*objectname)%1f%(objectname)", "refs/tags" }, false) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.GitFailed,
        };
    };
    defer out.deinit(runner.allocator);
    if (!out.ok()) return error.GitFailed;

    var tags: std.ArrayList(Tag) = .empty;
    errdefer tags.deinit(runner.allocator);
    try parseInto(runner.allocator, out.stdout, &tags);
    return tags.toOwnedSlice(runner.allocator);
}

/// Free a tag list produced by `listAll`. `Tag` owns its strings because the
/// buffer they were parsed from is freed before the caller sees them.
pub fn freeAll(allocator: std.mem.Allocator, list: []const Tag) void {
    for (list) |t| {
        allocator.free(t.name);
        allocator.free(t.commit);
    }
    allocator.free(list);
}

/// Split `for-each-ref` output into tags. Kept separate so it is unit-tested
/// without a repository.
pub fn parseInto(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Tag)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\x1f');
        const name = f.next() orelse continue;
        const peeled = f.next() orelse continue;
        const direct = f.next() orelse continue;
        // Annotated tags have a peeled object; lightweight tags do not.
        const commit = if (peeled.len != 0) peeled else direct;
        // The version is inferred later; store the bare parse under a `v`-or-
        // bare tolerant rule so filtering works for both spellings.
        const version = semver.parseWithStyle(.{ .prefix = "v" }, name) orelse continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .commit = try allocator.dupe(u8, commit),
            .version = version,
        });
    }
}

/// Pick the release boundary: the highest version tag reachable from `HEAD`.
pub fn select(runner: git.Runner, all: []const Tag, head: []const u8) Selection {
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    for (all) |t| fbs.print("{s}\n", .{t.name}) catch break;
    var selection = Selection{ .style = semver.inferStyle(fbs.buffered()) };

    var best: ?Tag = null;
    for (all) |t| {
        // A prerelease is not a release boundary: `v1.0.0-rc.1` must not make
        // the release after it look like it has nothing to list.
        if (t.version.isPrerelease()) continue;
        if (!isAncestor(runner, t.commit, head)) continue;
        if (best == null or semver.Semver.order(t.version, best.?.version) == .gt) {
            best = t;
        }
    }
    selection.latest = best;
    return selection;
}

/// `git merge-base --is-ancestor`. Exit 1 means "no", which is not an error.
pub fn isAncestor(runner: git.Runner, ancestor: []const u8, descendant: []const u8) bool {
    const out = runner.run(&.{ "git", "merge-base", "--is-ancestor", ancestor, descendant }, true) catch return false;
    defer out.deinit(runner.allocator);
    return out.ok();
}

test "parses lightweight and annotated refs" {
    const a = std.testing.allocator;
    var tags: std.ArrayList(Tag) = .empty;
    defer {
        for (tags.items) |t| {
            a.free(t.name);
            a.free(t.commit);
        }
        tags.deinit(a);
    }
    const text = "v0.7.0\x1f\x1fa1b2c3\nv0.8.0\x1fdeadbeef\x1ftagobject\nnightly\x1f\x1fdeadbeef\nnot-a-version\x1f\x1fx\n";
    try parseInto(a, text, &tags);
    try std.testing.expectEqual(@as(usize, 2), tags.items.len);
    try std.testing.expectEqualStrings("v0.7.0", tags.items[0].name);
    try std.testing.expectEqualStrings("a1b2c3", tags.items[0].commit);
    // Annotated tags use the peeled commit, not the tag object.
    try std.testing.expectEqualStrings("deadbeef", tags.items[1].commit);
}
