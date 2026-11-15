//! Finding the changelog file.
//!
//! A repository usually has exactly one, but the rules still need to be
//! explainable: `chgl detect` prints the ranking and the reason for the pick,
//! because "why did it choose that file?" is the first question after a wrong
//! guess.
//!
//! The candidate list is fixed and shallow on purpose. Walking the tree would
//! find `node_modules/**/CHANGELOG.md` and vendored dependencies, and v1 does
//! not support monorepos.

const std = @import("std");

pub const Format = enum {
    /// `## [1.2.3] - date` and `### Added`.
    keep_a_changelog,
    /// `## 1.2.3` and/or `### Features`, `### Bug Fixes`.
    plain_markdown,
    /// Detected, but not Markdown: reported and refused.
    not_markdown,
    /// Detected, but generated from fragments (`.changeset/`, towncrier).
    fragments,
    /// Detected but unreadable as a changelog.
    unknown,

    pub fn name(self: Format) []const u8 {
        return switch (self) {
            .keep_a_changelog => "Keep a Changelog",
            .plain_markdown => "Markdown changelog",
            .not_markdown => "not Markdown",
            .fragments => "fragment-based",
            .unknown => "unrecognised",
        };
    }

    /// Can `chgl` write a section into this file?
    pub fn writable(self: Format) bool {
        return self == .keep_a_changelog or self == .plain_markdown;
    }
};

pub const Candidate = struct {
    path: []const u8,
    score: u32,
    reason: []const u8,
    format: Format,
};

pub const Result = struct {
    /// Highest-scoring candidate, if any was found.
    chosen: ?Candidate = null,
    /// All candidates, best first.
    ranked: []Candidate = &.{},
    /// A fragment directory was found (`.changeset/`, `news/`, `changelog.d/`).
    fragment_dir: ?[]const u8 = null,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.ranked);
    }
};

/// Filesystem probe, so detection is testable without touching disk.
pub const Probe = struct {
    ctx: *anyopaque,
    exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
    read: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]u8,

    pub fn existsOn(self: Probe, path: []const u8) bool {
        return self.exists(self.ctx, path);
    }

    /// File contents, or null when absent or unreadable.
    pub fn readAlloc(self: Probe, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        return self.read(self.ctx, allocator, path);
    }
};

const TIER_EXACT_ROOT: u32 = 100;
const TIER_EXACT_SUBDIR: u32 = 90;
const TIER_STRUCTURE: u32 = 70;

const KNOWN_MARKDOWN = [_][]const u8{
    "CHANGELOG.md",
    "Changelog.md",
    "changelog.md",
    "CHANGES.md",
    "Changelog.markdown",
    "HISTORY.md",
    "NEWS.md",
    "RELEASE_NOTES.md",
    "RELEASE-NOTES.md",
    "NOTES.md",
};

const KNOWN_NON_MARKDOWN = [_][]const u8{
    "CHANGELOG",
    "CHANGELOG.rst",
    "CHANGES.rst",
    "HISTORY.rst",
    "NEWS.rst",
    "CHANGELOG.txt",
    "CHANGES.txt",
    "CHANGELOG.adoc",
    "debian/changelog",
};

const KNOWN_DIRS = [_][]const u8{ "", "docs/", ".github/", "doc/", "Documentation/" };

const FRAGMENT_DIRS = [_][]const u8{ ".changeset", "changelog.d", "news", "changes" };

pub const Error = error{OutOfMemory};

/// Find the changelog. `forced` skips detection entirely.
pub fn detect(allocator: std.mem.Allocator, probe: Probe, forced: ?[]const u8) Error!Result {
    if (forced) |path| {
        const text = probe.readAlloc(allocator, path);
        const format = if (text) |t| inferFormat(t) else Format.unknown;
        if (text) |t| allocator.free(t);
        const ranked = try allocator.alloc(Candidate, 1);
        ranked[0] = .{ .path = path, .score = TIER_EXACT_ROOT, .reason = "given with --file", .format = format };
        return .{ .chosen = ranked[0], .ranked = ranked };
    }

    var list: std.ArrayList(Candidate) = .empty;
    errdefer list.deinit(allocator);

    for (KNOWN_DIRS) |dir| {
        for (KNOWN_MARKDOWN) |name| {
            const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, name });
            defer allocator.free(path);
            try consider(allocator, &list, probe, path, if (dir.len == 0) TIER_EXACT_ROOT else TIER_EXACT_SUBDIR, "known changelog name", true);
        }
        for (KNOWN_NON_MARKDOWN) |name| {
            const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, name });
            defer allocator.free(path);
            const is_markdown = false;
            const score = if (dir.len == 0) TIER_EXACT_ROOT else TIER_EXACT_SUBDIR;
            try considerNonMarkdown(allocator, &list, probe, path, score, is_markdown);
        }
    }

    // A `*.changelog` file (e.g. `debian/changelog`) is recognised and refused.
    for (KNOWN_DIRS) |dir| {
        const path = try std.fmt.allocPrint(allocator, "{s}changelog", .{dir});
        defer allocator.free(path);
        try considerNonMarkdown(allocator, &list, probe, path, 80, false);
    }

    var fragment_dir: ?[]const u8 = null;
    for (FRAGMENT_DIRS) |d| {
        if (probe.existsOn(d)) {
            fragment_dir = d;
            try list.append(allocator, .{
                .path = try allocator.dupe(u8, d),
                .score = 75,
                .reason = "fragment directory",
                .format = .fragments,
            });
            break;
        }
    }

    sortDescending(list.items);
    const ranked = try list.toOwnedSlice(allocator);
    return .{
        .chosen = if (ranked.len != 0) ranked[0] else null,
        .ranked = ranked,
        .fragment_dir = fragment_dir,
    };
}

fn consider(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Candidate),
    probe: Probe,
    path: []const u8,
    score: u32,
    reason: []const u8,
    markdown: bool,
) Error!void {
    if (!probe.existsOn(path)) return;
    const text = probe.readAlloc(allocator, path) orelse return;
    defer allocator.free(text);
    const format = if (markdown) inferFormat(text) else Format.not_markdown;
    try list.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .score = score,
        .reason = reason,
        .format = format,
    });
}

fn considerNonMarkdown(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Candidate),
    probe: Probe,
    path: []const u8,
    score: u32,
    _: bool,
) Error!void {
    if (!probe.existsOn(path)) return;
    try list.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .score = score,
        .reason = "known changelog name, not Markdown",
        .format = .not_markdown,
    });
}

fn sortDescending(items: []Candidate) void {
    // Insertion sort: the list is a few dozen entries at most, and a stable
    // order keeps equal scores in table order (root names before docs/).
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        var j = i;
        while (j > 0 and items[j - 1].score < item.score) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = item;
    }
}

/// A `# Title` file with no version headings yet is still a changelog the user
/// asked us to maintain; treat it as Keep a Changelog so it can be started.
fn looksLikeChangelogTitle(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var budget: usize = 5;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        budget -|= 1;
        if (budget == 0) return false;
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "#")) return false;
        line = std.mem.trimStart(u8, line[1..], "#");
        line = std.mem.trim(u8, line, " \t");
        const words = [_][]const u8{ "changelog", "changes", "history", "news", "release notes" };
        for (words) |w| {
            if (std.ascii.eqlIgnoreCase(line, w)) return true;
            if (std.ascii.eqlIgnoreCase(line, "Changelog")) return true;
        }
        return false;
    }
    return false;
}

fn isUnreleasedWord(label: []const u8) bool {
    for ([_][]const u8{ "Unreleased", "unreleased", "Next", "TBD" }) |w| {
        if (std.mem.eql(u8, label, w)) return true;
    }
    return false;
}

/// Which Markdown changelog shape this is, from its headings.
pub fn inferFormat(text: []const u8) Format {
    var bracket_headings: usize = 0;
    var plain_headings: usize = 0;
    var kac_groups: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "## [")) bracket_headings += 1;
        if (std.mem.startsWith(u8, line, "## ")) {
            const label = std.mem.trim(u8, line[3..], " \t#");
            if (isUnreleasedWord(label)) {
                bracket_headings += 1;
            } else if (!std.mem.startsWith(u8, line, "## [")) {
                plain_headings += 1;
            }
        }
        if (std.mem.startsWith(u8, line, "### ")) {
            const name = std.mem.trim(u8, line[4..], " \t");
            for ([_][]const u8{ "Added", "Changed", "Deprecated", "Removed", "Fixed", "Security" }) |g| {
                if (std.mem.eql(u8, name, g)) kac_groups += 1;
            }
        }
    }
    if (bracket_headings != 0 or kac_groups != 0) return .keep_a_changelog;
    if (plain_headings != 0) return .plain_markdown;
    if (looksLikeChangelogTitle(text)) return .keep_a_changelog;
    return .unknown;
}

test "root CHANGELOG.md wins over docs/" {
    const a = std.testing.allocator;
    var fake = FakeFs{ .paths = &.{ "CHANGELOG.md", "docs/CHANGELOG.md" } };
    const r = try detect(a, fake.probe(), null);
    defer freeResult(a, r);
    try std.testing.expectEqualStrings("CHANGELOG.md", r.chosen.?.path);
}

test "a markdown file that mentions changelog is not a candidate" {
    const a = std.testing.allocator;
    var fake = FakeFs{ .paths = &.{"notes.md"} };
    const r = try detect(a, fake.probe(), null);
    defer freeResult(a, r);
    try std.testing.expect(r.chosen == null);
}

test "CHANGELOG.rst is detected and refused" {
    const a = std.testing.allocator;
    var fake = FakeFs{ .paths = &.{"CHANGELOG.rst"} };
    const r = try detect(a, fake.probe(), null);
    defer freeResult(a, r);
    try std.testing.expectEqualStrings("CHANGELOG.rst", r.chosen.?.path);
    try std.testing.expectEqual(Format.not_markdown, r.chosen.?.format);
    try std.testing.expect(!r.chosen.?.format.writable());
}

test "fragment directories are reported" {
    const a = std.testing.allocator;
    var fake = FakeFs{ .paths = &.{".changeset"} };
    const r = try detect(a, fake.probe(), null);
    defer freeResult(a, r);
    try std.testing.expectEqualStrings(".changeset", r.fragment_dir.?);
}

test "inferFormat distinguishes shapes" {
    try std.testing.expectEqual(Format.keep_a_changelog, inferFormat("# C\n\n## [1.0.0]\n\n### Added\n"));
    try std.testing.expectEqual(Format.keep_a_changelog, inferFormat("# C\n\n## Unreleased\n"));
    try std.testing.expectEqual(Format.plain_markdown, inferFormat("# C\n\n## 0.13.8\n\n### Python\n"));
    try std.testing.expectEqual(Format.unknown, inferFormat("# C\n\njust prose\n"));
}

fn freeResult(a: std.mem.Allocator, r: Result) void {
    for (r.ranked) |c| a.free(c.path);
    r.deinit(a);
}

const FakeFs = struct {
    paths: []const []const u8,
    contents: []const []const u8 = &.{},

    fn probe(self: *FakeFs) Probe {
        return .{ .ctx = self, .exists = existsFn, .read = readFn };
    }

    fn existsFn(ctx: *anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.paths) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.paths, 0..) |p, i| {
            if (!std.mem.eql(u8, p, path)) continue;
            if (i < self.contents.len) return allocator.dupe(u8, self.contents[i]) catch null;
            return allocator.dupe(u8, "") catch null;
        }
        return null;
    }
};
