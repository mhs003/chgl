//! Commit range → entries → plan.
//!
//! Every decision here is data, not a side effect: an entry is `keep`, `skip`,
//! or `ask`, and *why* it was skipped is an enum so the TUI can print a reason
//! and headless mode can warn. Nothing is dropped without a recorded reason.

const std = @import("std");
const Commit = @import("../git/commit.zig");
const log = @import("../git/log.zig");
const semver = @import("../version/semver.zig");
const glob = @import("../util/glob.zig");

pub const State = enum {
    keep,
    skip,
    /// Needs a human decision: a non-conventional commit whose content the
    /// author may still want listed.
    ask,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .keep => "Keep",
            .skip => "Skip",
            .ask => "Ask",
        };
    }
};

pub const SkipReason = enum {
    none,
    /// A merge commit, and `--parse-merges` was not given.
    merge,
    /// The release automation's own commit.
    release_commit,
    /// Matched an `--exclude` glob.
    excluded,
    /// Not Conventional Commits.
    unconventional,
    /// Kept out by the caller (e.g. everything is skipped in headless mode).
    user,

    pub fn label(self: SkipReason) []const u8 {
        return switch (self) {
            .none => "",
            .merge => "merge commit",
            .release_commit => "release commit",
            .excluded => "excluded",
            .unconventional => "not a conventional commit",
            .user => "skipped",
        };
    }
};

/// Keep a Changelog sections, in render order.
pub const Group = enum {
    breaking,
    added,
    changed,
    deprecated,
    removed,
    fixed,
    security,
    performance,
    documentation,
    build,
    ci,
    tests,
    styles,
    reverted,
    maintenance,
    other,

    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .breaking => "Breaking Changes",
            .added => "Added",
            .changed => "Changed",
            .deprecated => "Deprecated",
            .removed => "Removed",
            .fixed => "Fixed",
            .security => "Security",
            .performance => "Performance",
            .documentation => "Documentation",
            .build => "Build",
            .ci => "CI",
            .tests => "Tests",
            .styles => "Styles",
            .reverted => "Reverted",
            .maintenance => "Maintenance",
            .other => "Other",
        };
    }

    /// The `Added`/`Fixed` vocabulary some changelogs use instead.
    pub fn alias(self: Group) ?[]const u8 {
        return switch (self) {
            .added => "Features",
            .fixed => "Bug Fixes",
            .documentation => "Docs",
            .maintenance => "Chores",
            else => null,
        };
    }

    /// Inverse of `title`, including the alias spellings some files use.
    pub fn fromTitle(text: []const u8) ?Group {
        inline for (@typeInfo(Group).@"enum".fields) |f| {
            const g: Group = @enumFromInt(f.value);
            if (std.mem.eql(u8, g.title(), text)) return g;
            if (g.alias()) |a| {
                if (std.mem.eql(u8, a, text)) return g;
            }
        }
        return null;
    }

    pub fn fromKind(kind: Commit.Kind) Group {
        return switch (kind) {
            .feat => .added,
            .fix => .fixed,
            .perf => .performance,
            .refactor => .changed,
            .revert => .reverted,
            .docs => .documentation,
            .chore => .maintenance,
            .ci => .ci,
            .@"test" => .tests,
            .style => .styles,
            .build => .build,
            .other, .unparsed => .other,
        };
    }
};

pub const Entry = struct {
    /// Commit subject as written.
    subject: []const u8,
    short_hash: []const u8,
    parsed: Commit.Parsed,
    /// Group it will render under.
    group: Group,
    /// The group its commit type implies. Equal to `group` except for breaking
    /// entries, which render under Breaking Changes *and* under this one.
    type_group: Group,
    state: State,
    reason: SkipReason,
    /// Breaking marks the entry in Breaking Changes as well as its group.
    breaking: bool,
    /// Rewritten wording from the optional polish pass, if any.
    title: ?[]const u8 = null,
    /// The file's own wording when this entry was absorbed from `[Unreleased]`.
    from_file: bool = false,
    /// Owned copies of `subject`/`short_hash`, freed in `Release.deinit`.
    owned_subject: ?[]u8 = null,
    owned_short: ?[]u8 = null,
    owned_title: ?[]u8 = null,

    pub fn text(self: Entry) []const u8 {
        return self.title orelse self.parsed.description;
    }

    pub fn countable(self: Entry) bool {
        return self.state == .keep;
    }

    /// Does this entry justify a release on its own?
    pub fn releasable(self: Entry) bool {
        if (!self.countable()) return false;
        if (self.from_file) return true;
        return self.breaking or self.parsed.kind.releasable();
    }

    /// Whether the wording is worth a model rewrite: unparsed subjects and
    /// entries with no scope read worst.
    pub fn needs_polish(self: Entry) bool {
        if (self.from_file) return false;
        if (self.parsed.kind == .unparsed) return true;
        if (self.group == .other) return true;
        return false;
    }
};

pub const Options = struct {
    parse_merges: bool = false,
    /// Headless mode turns "ask" into "skip" with a warning; the TUI keeps it
    /// as "ask" so the user sees it.
    interactive: bool = false,
    exclude: []const []const u8 = &.{},
};

pub const Release = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Commits read from the range, excluding none.
    total: usize = 0,
    merges: usize = 0,

    pub fn deinit(self: *Release, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            if (e.owned_subject) |s| allocator.free(s);
            if (e.owned_short) |s| allocator.free(s);
            if (e.owned_title) |s| allocator.free(s);
            // Parsed text is owned by the entry (see `Commit.parse`).
            if (e.from_file) continue;
            allocator.free(e.parsed.type_name);
            if (e.parsed.scope) |sc| allocator.free(sc);
            allocator.free(e.parsed.description);
            if (e.parsed.breaking_note) |bn| allocator.free(bn);
        }
        self.entries.deinit(allocator);
    }

    pub fn kept(self: Release) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.countable()) n += 1;
        }
        return n;
    }

    pub fn count(self: Release, state: State) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.state == state) n += 1;
        }
        return n;
    }

    pub fn hasBreaking(self: Release) bool {
        for (self.entries.items) |e| {
            if (e.countable() and e.breaking) return true;
        }
        return false;
    }

    pub fn hasFeature(self: Release) bool {
        for (self.entries.items) |e| {
            if (e.countable() and (e.parsed.kind == .feat or e.from_file)) return true;
        }
        return false;
    }

    /// At least one kept entry that justifies a release.
    pub fn releasable(self: Release) bool {
        for (self.entries.items) |e| {
            if (e.releasable()) return true;
        }
        return false;
    }
};

/// Build the release from a commit list. Owns nothing from `commits`; the
/// caller keeps the log alive for the life of the release.
pub fn build(
    allocator: std.mem.Allocator,
    commits: []const log.Record,
    opts: Options,
) !Release {
    var release = Release{ .total = commits.len };
    errdefer release.deinit(allocator);

    for (commits) |c| {
        if (c.isMerge()) release.merges += 1;

        var reason: SkipReason = .none;
        if (c.isMerge() and !opts.parse_merges) reason = .merge else if (isReleaseCommit(c.subject)) reason = .release_commit else if (matchesAny(opts.exclude, c.subject)) reason = .excluded;

        const owned_subject = try allocator.dupe(u8, c.subject);
        const owned_short = try allocator.dupe(u8, c.short);
        var parsed = try Commit.parse(allocator, c.subject, c.body);
        const breaking = parsed.parsed.breaking;
        const type_group = Group.fromKind(parsed.parsed.kind);
        const group: Group = if (breaking) .breaking else type_group;

        var state: State = .keep;
        if (reason != .none) {
            state = .skip;
        } else if (!parsed.parsed.isConventional()) {
            reason = .unconventional;
            state = if (opts.interactive) .ask else .skip;
        }

        try release.entries.append(allocator, .{
            // Copy: the log buffer is freed when the caller is done reading it,
            // and a plan outlives that (the TUI holds it for a whole session).
            .subject = owned_subject,
            .short_hash = owned_short,
            .owned_subject = owned_subject,
            .owned_short = owned_short,
            .parsed = parsed.takeParsed(),
            .type_group = type_group,
            .group = group,
            .state = state,
            .reason = reason,
            .breaking = breaking,
        });
    }
    return release;
}

/// `chore(release): …` and friends, whatever the casing of the scope.
pub fn isReleaseCommit(subject: []const u8) bool {
    const lower_prefixes = [_][]const u8{ "chore(release)", "chore(version)", "chore: release", "chore: bump version", "chore: prepare" };
    for (lower_prefixes) |p| {
        if (subject.len >= p.len and std.ascii.eqlIgnoreCase(subject[0..p.len], p)) return true;
    }
    return false;
}

fn matchesAny(patterns: []const []const u8, subject: []const u8) bool {
    for (patterns) |p| {
        if (glob.matches(p, subject)) return true;
    }
    return false;
}

/// The version this release implies, or null when a bump cannot be derived
/// (no current version). `bumps` is the comma list from `[version] bump`:
/// `auto` uses the semver rule, otherwise the named part is bumped.
pub fn nextVersion(current: semver.Semver, release: Release, bumps: []const u8) semver.Semver {
    if (std.mem.eql(u8, bumps, "auto")) {
        const b = semver.bumpFor(current, release.hasBreaking(), release.hasFeature());
        return semver.apply(current, b);
    }
    if (std.mem.eql(u8, bumps, "major")) return semver.apply(current, .major);
    if (std.mem.eql(u8, bumps, "minor")) return semver.apply(current, .minor);
    if (std.mem.eql(u8, bumps, "patch")) return semver.apply(current, .patch);
    return semver.apply(current, .patch);
}

test "classifies conventional commits into groups" {
    const a = std.testing.allocator;
    const commits = [_]log.Record{
        rec("feat(cli): add --dry-run"),
        rec("fix: stop the drift"),
        rec("docs: readme"),
        rec("chore(release): v0.7.4"),
        rec("updated the readme"),
    };
    var r = try build(a, &commits, .{});
    defer r.deinit(a);

    try std.testing.expectEqual(@as(usize, 5), r.entries.items.len);
    try std.testing.expectEqual(Group.added, r.entries.items[0].group);
    try std.testing.expectEqual(Group.fixed, r.entries.items[1].group);
    try std.testing.expectEqual(State.skip, r.entries.items[3].state);
    try std.testing.expectEqual(SkipReason.release_commit, r.entries.items[3].reason);
    // Headless: unconventional is skipped, with a reason.
    try std.testing.expectEqual(State.skip, r.entries.items[4].state);
    try std.testing.expectEqual(SkipReason.unconventional, r.entries.items[4].reason);
}

test "interactive keeps unconventional as ask" {
    const a = std.testing.allocator;
    const commits = [_]log.Record{ rec("wip"), rec("updated the readme") };
    var r = try build(a, &commits, .{ .interactive = true });
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), r.count(.ask));
    try std.testing.expectEqual(@as(usize, 0), r.kept());
}

test "merge commits are skipped unless asked for" {
    const a = std.testing.allocator;
    var m = rec("Merge branch 'feat/x'");
    m.parents = "p1 p2";
    const commits = [_]log.Record{ m, rec("feat: real") };
    {
        var r = try build(a, &commits, .{});
        defer r.deinit(a);
        try std.testing.expectEqual(State.skip, r.entries.items[0].state);
        try std.testing.expectEqual(SkipReason.merge, r.entries.items[0].reason);
        try std.testing.expectEqual(@as(usize, 1), r.merges);
    }
    {
        var r = try build(a, &commits, .{ .parse_merges = true });
        defer r.deinit(a);
        // Parsed as an entry now, but still non-conventional.
        try std.testing.expectEqual(SkipReason.unconventional, r.entries.items[0].reason);
    }
}

test "exclude globs match the subject" {
    const a = std.testing.allocator;
    const commits = [_]log.Record{ rec("Merge branch 'x'"), rec("feat: keep me") };
    var r = try build(a, &commits, .{ .exclude = &.{"Merge *"}, .parse_merges = true });
    defer r.deinit(a);
    try std.testing.expectEqual(SkipReason.excluded, r.entries.items[0].reason);
    try std.testing.expectEqual(State.keep, r.entries.items[1].state);
}

test "releasable needs a kept feat/fix/breaking" {
    const a = std.testing.allocator;
    const docs_only = [_]log.Record{ rec("docs: readme"), rec("chore: tidy") };
    var r1 = try build(a, &docs_only, .{});
    defer r1.deinit(a);
    try std.testing.expect(!r1.releasable());

    const with_fix = [_]log.Record{rec("fix: a bug")};
    var r2 = try build(a, &with_fix, .{});
    defer r2.deinit(a);
    try std.testing.expect(r2.releasable());
}

test "breaking marks the group and drives the bump" {
    const a = std.testing.allocator;
    const commits = [_]log.Record{rec("refactor(core)!: replace the store")};
    var r = try build(a, &commits, .{});
    defer r.deinit(a);
    try std.testing.expectEqual(Group.breaking, r.entries.items[0].group);
    try std.testing.expect(r.hasBreaking());
    const at1 = semver.Semver.parse("1.2.3").?;
    const next = nextVersion(at1, r, "auto");
    try std.testing.expectEqual(@as(u32, 2), next.major);
}

test "group titles round-trip through aliases" {
    try std.testing.expectEqual(Group.added, Group.fromTitle("Features").?);
    try std.testing.expectEqual(Group.fixed, Group.fromTitle("Bug Fixes").?);
    try std.testing.expectEqual(Group.added, Group.fromTitle("Added").?);
    try std.testing.expectEqual(null, Group.fromTitle("Whimsy"));
}

fn rec(subject: []const u8) log.Record {
    return .{ .hash = "0000", .short = "0000000", .timestamp = 0, .author_name = "A", .author_email = "a@x", .parents = "p", .subject = subject, .body = "" };
}
