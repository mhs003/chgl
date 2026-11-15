//! Rendering a release section as Markdown.
//!
//! Output shape matches what the reference project's release script produced,
//! because that has been read by users for a year: a `## [x] - date` heading,
//! `### Group` subsections, and one `- ` bullet per entry with `**scope:**`
//! in bold. The one difference is that groups come from the commit type and
//! the file's own vocabulary, not a fixed three-way split.

const std = @import("std");
const entry_mod = @import("release/entry.zig");
const Entry = entry_mod.Entry;
const Group = entry_mod.Group;

pub const LinkStyle = struct {
    /// `https://github.com/o/r`, or null to leave refs as plain text.
    repo_url: ?[]const u8 = null,
    /// Append `([abc1234](…/commit/abc1234))`.
    commit_links: bool = false,
    /// Link `#42` to `…/issues/42`.
    issue_links: bool = true,
};

pub const Options = struct {
    heading: []const u8,
    entries: []const Entry,
    /// Titles the file already uses, so a changelog written with `Features`
    /// keeps saying `Features`.
    vocabulary: []const []const u8 = &.{},
    links: LinkStyle = .{},
    eol: []const u8 = "\n",
};

/// The section body: groups and bullets, without the version heading.
pub fn body(allocator: std.mem.Allocator, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Render groups in enum order, breaking first.
    inline for (@typeInfo(Group).@"enum".fields) |f| {
        const group: Group = @enumFromInt(f.value);
        if (groupHasEntries(opts.entries, group)) {
            try out.print(allocator, "### {s}{s}{s}", .{ groupTitle(group, opts.vocabulary), opts.eol, opts.eol });
            for (opts.entries) |e| {
                if (!e.countable()) continue;
                const in_group = e.group == group or e.type_group == group;
                if (!in_group) continue;
                try entryLine(allocator, &out, e, opts);
            }
            try out.appendSlice(allocator, opts.eol);
        }
    }
    // Trim the trailing blank line; the inserter adds its own spacing.
    const trimmed = std.mem.trimEnd(u8, out.items, " \t\r\n");
    out.shrinkRetainingCapacity(trimmed.len);
    return out.toOwnedSlice(allocator);
}

/// Full section including the heading, as it would appear in the file.
pub fn section(allocator: std.mem.Allocator, opts: Options) ![]u8 {
    const b = try body(allocator, opts);
    defer allocator.free(b);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ opts.heading, opts.eol, opts.eol, b });
}

/// The file's spelling of a group, else the canonical one.
pub fn groupTitle(group: Group, vocabulary: []const []const u8) []const u8 {
    for (vocabulary) |v| {
        if (Group.fromTitle(v)) |g| {
            if (g == group) return v;
        }
    }
    return group.title();
}

fn groupHasEntries(entries: []const Entry, group: Group) bool {
    for (entries) |e| {
        if (!e.countable()) continue;
        if (e.group == group or e.type_group == group) return true;
    }
    return false;
}

fn entryLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), e: Entry, opts: Options) !void {
    try out.appendSlice(allocator, "- ");
    if (e.parsed.scope) |scope| {
        if (scope.len != 0) try out.print(allocator, "**{s}:** ", .{scope});
    }
    try out.appendSlice(allocator, e.text());

    // Issue references, linked when the remote is known.
    if (e.parsed.refs.len != 0) {
        if (opts.links.issue_links and opts.links.repo_url != null) {
            // The refs are already inside the text; replace each plain `#N`
            // occurrence with a link, once.
            const linked = try linkRefs(allocator, out.items, e.parsed.refs, opts.links.repo_url.?);
            out.clearRetainingCapacity();
            try out.appendSlice(allocator, linked);
            allocator.free(linked);
        }
    }
    if (opts.links.commit_links) {
        if (opts.links.repo_url) |repo| {
            try out.print(allocator, " ([{s}]({s}/commit/{s}))", .{ e.short_hash, repo, e.short_hash });
        } else {
            try out.print(allocator, " ({s})", .{e.short_hash});
        }
    }
    try out.appendSlice(allocator, opts.eol);
}

/// Replace `#12` with `[#12](url/issues/12)`. Only whole references are
/// replaced, so `#1` cannot match inside `#10`.
fn linkRefs(allocator: std.mem.Allocator, text: []const u8, refs: []const []const u8, repo: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '#') {
            var j = i + 1;
            while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
            if (j > i + 1) {
                const ref = text[i..j];
                var known = false;
                for (refs) |r| {
                    if (std.mem.eql(u8, r, ref)) known = true;
                }
                if (known) {
                    try out.print(allocator, "[{s}]({s}/issues/{s})", .{ ref, repo, ref[1..] });
                    i = j;
                    continue;
                }
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "renders groups with scope bold" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        testEntry("feat(cli): add --dry-run", .added, .feat, "cli", false),
        testEntry("fix: stop the drift", .fixed, .fix, null, false),
    };
    const out = try body(a, .{ .heading = "", .entries = &entries });
    defer a.free(out);
    try std.testing.expectEqualStrings("### Added\n\n- **cli:** add --dry-run\n\n### Fixed\n\n- stop the drift", out);
}

test "breaking entries render under their own group and their type group" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        testEntry("refactor(core)!: replace the store", .breaking, .refactor, "core", true),
    };
    const out = try body(a, .{ .heading = "", .entries = &entries });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "### Breaking Changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "### Changed") != null);
}

test "the file's vocabulary wins" {
    const a = std.testing.allocator;
    const entries = [_]Entry{testEntry("feat: x", .added, .feat, null, false)};
    const vocab = [_][]const u8{ "Features", "Bug Fixes" };
    const out = try body(a, .{ .heading = "", .entries = &entries, .vocabulary = &vocab });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "### Features") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "### Added") == null);
}

test "skipped entries are not rendered" {
    const a = std.testing.allocator;
    var e = testEntry("feat: hidden", .added, .feat, null, false);
    e.state = .skip;
    const entries = [_]Entry{e};
    const out = try body(a, .{ .heading = "", .entries = &entries });
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "issue refs are linked once and prefix-safe" {
    const a = std.testing.allocator;
    var e = testEntry("fix: handle #10 and #1", .fixed, .fix, null, false);
    e.parsed.refs = &.{ "#10", "#1" };
    const entries = [_]Entry{e};
    const out = try body(a, .{ .heading = "", .entries = &entries, .links = .{ .repo_url = "https://github.com/o/r" } });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[#10](https://github.com/o/r/issues/10)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[#1](https://github.com/o/r/issues/1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "issues/100") == null);
}

fn testEntry(subject: []const u8, group: Group, kind: @import("git/commit.zig").Kind, scope: ?[]const u8, breaking: bool) Entry {
    return .{
        .subject = subject,
        .short_hash = "abc1234",
        .parsed = .{
            .kind = kind,
            .type_name = "",
            .scope = scope,
            .description = descriptionOf(subject),
            .breaking = breaking,
            .breaking_note = null,
            .refs = &.{},
        },
        .group = group,
        .type_group = if (group == .breaking) .changed else group,
        .state = .keep,
        .reason = .none,
        .breaking = breaking,
    };
}

fn descriptionOf(subject: []const u8) []const u8 {
    const colon = std.mem.indexOf(u8, subject, ": ") orelse return subject;
    return subject[colon + 2 ..];
}
