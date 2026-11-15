//! The file shape `chgl init` writes, and the checks that decide whether a
//! file may be started.
//!
//! Kept apart from the command so the rules are testable without a repository:
//! what counts as "already has releases", what counts as "title only", and
//! exactly which bytes get written.

const std = @import("std");
const semver = @import("version/semver.zig");

/// A changelog with nothing in it yet. The heading text matches what the TUI
/// and `detect` recognise, so the next run keeps maintaining this file.
pub const empty_text =
    \\# Changelog
    \\
    \\All notable changes to this project are documented here.
    \\
    \\The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
    \\
    \\## [Unreleased]
    \\
;

pub fn empty(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, empty_text);
}

/// True when the file already has a released section, so there is nothing to
/// create. `## [Unreleased]` alone does not count: a file with only that is a
/// changelog the user has started and can keep using.
pub fn hasVersionHeading(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const label = headingLabel(line) orelse continue;
        if (isUnreleased(label)) continue;
        if (semver.parseWithStyle(.{ .prefix = "v" }, label) != null) return true;
    }
    return false;
}

/// True when the file already has an `## [Unreleased]` heading, which is where
/// the next release section goes. Such a file is ready; `init` leaves it be.
pub fn hasUnreleased(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const label = headingLabel(std.mem.trim(u8, raw, " \t\r")) orelse continue;
        if (isUnreleased(label)) return true;
    }
    return false;
}

fn isUnreleased(label: []const u8) bool {
    return std.ascii.eqlIgnoreCase(label, "Unreleased");
}

/// For a file whose only content is a title (and optionally blank lines or an
/// underline), return the bytes after the title so they can be kept. Null means
/// the file has real content and must not be touched.
pub fn titleOnly(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen_title = false;
    var consumed: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // A line's consumed length is its own bytes plus the newline that
        // separated it; the last line may have none.
        const advance = raw.len + @intFromBool(lines.index != null);
        if (line.len == 0) {
            consumed += advance;
            continue;
        }
        if (!seen_title) {
            if (!std.mem.startsWith(u8, line, "#")) return null;
            // A second heading level means structure, not a bare title.
            if (!std.mem.startsWith(u8, line, "# ")) return null;
            seen_title = true;
            consumed += advance;
            continue;
        }
        // `TITLE` + `=====` is still a title block.
        if (isRuler(line)) {
            consumed += advance;
            continue;
        }
        return null;
    }
    if (!seen_title) return null;
    return text[@min(consumed, text.len)..];
}

fn isRuler(line: []const u8) bool {
    if (line.len == 0) return false;
    for (line) |c| if (c != '=' and c != '-' and c != '#') return false;
    return true;
}

/// The label of a `## [1.2.3]` / `## 1.2.3` heading, or null for other lines.
fn headingLabel(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "## ")) return null;
    var rest = std.mem.trim(u8, line[3..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        rest = rest[1..close];
    } else if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
        // `## 1.2.3 — date`: the label stops at the first space.
        rest = rest[0..sp];
    }
    return std.mem.trim(u8, rest, " \t");
}

/// Start a title-only file: keep the title block, then add the empty sections,
/// so the file the user wrote stays exactly as they wrote it.
pub fn startExisting(allocator: std.mem.Allocator, text: []const u8, tail: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const title = text[0 .. text.len - tail.len];
    try out.appendSlice(allocator, title);
    if (title.len != 0 and !std.mem.endsWith(u8, title, "\n")) try out.append(allocator, '\n');
    // One blank line between the title block and the first heading.
    if (!std.mem.endsWith(u8, out.items, "\n\n")) try out.append(allocator, '\n');
    try out.appendSlice(allocator, "## [Unreleased]\n");
    return out.toOwnedSlice(allocator);
}

test "the empty skeleton has an Unreleased heading and no releases" {
    const gpa = std.testing.allocator;
    const text = try empty(gpa);
    defer gpa.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "# Changelog\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "## [Unreleased]") != null);
    try std.testing.expect(!hasVersionHeading(text));
}

test "a released section stops init from overwriting" {
    try std.testing.expect(hasVersionHeading("## [1.2.3] - 2026-01-01\n\n- x\n"));
    try std.testing.expect(hasVersionHeading("## 1.2.3 — January 1, 2026\n"));
    try std.testing.expect(hasVersionHeading("## v1.2.3\n"));
    // Unreleased alone is not a release.
    try std.testing.expect(!hasVersionHeading("## [Unreleased]\n\n- a hand-written note\n"));
    // Neither is prose that happens to mention a number.
    try std.testing.expect(!hasVersionHeading("Some text\n\n- 1.2.3 was skipped\n"));
}

test "title-only files can be started, others cannot" {
    try std.testing.expect(titleOnly("# Changelog\n") != null);
    try std.testing.expect(titleOnly("# Changelog\n\n\n") != null);
    try std.testing.expect(titleOnly("# Changelog\n=====\n") != null);

    // Real content is never touched, and a nested heading is structure.
    try std.testing.expect(titleOnly("# Changelog\n\nSome notes about releases.\n") == null);
    try std.testing.expect(titleOnly("# Changelog\n\n## Usage\n") == null);
    try std.testing.expect(titleOnly("Just prose with no title\n") == null);
}

test "starting a title-only file keeps the title and adds Unreleased" {
    const gpa = std.testing.allocator;
    const text = "# Changelog\n";
    const started = try startExisting(gpa, text, titleOnly(text).?);
    defer gpa.free(started);
    try std.testing.expectEqualStrings("# Changelog\n\n## [Unreleased]\n", started);
    try std.testing.expect(!hasVersionHeading(started));
}

test "an underline title keeps its ruler" {
    const gpa = std.testing.allocator;
    const text = "# My Changelog\n=============\n";
    const started = try startExisting(gpa, text, titleOnly(text).?);
    defer gpa.free(started);
    try std.testing.expectEqualStrings("# My Changelog\n=============\n\n## [Unreleased]\n", started);
}
