//! Editing a parsed changelog.
//!
//! Every function here returns a *new* file as bytes. Nothing is written to
//! disk by this module: `main` decides when a write happens, and the TUI
//! previews the exact bytes the write will produce.

const std = @import("std");
const parse = @import("parse.zig");
const semver = @import("../version/semver.zig");

pub const Error = error{ OutOfMemory, Unparsable, SectionExists } || std.Io.Writer.Error;

pub const Eol = enum { lf, crlf };

pub fn eolOf(doc: parse.Document) Eol {
    return if (std.mem.eql(u8, doc.eol, "\r\n")) .crlf else .lf;
}

pub fn eolText(eol: Eol) []const u8 {
    return switch (eol) {
        .lf => "\n",
        .crlf => "\r\n",
    };
}

/// Where the new section goes, and what has to move with it.
pub const Placement = struct {
    /// Byte offset in the source file where the new section text is inserted.
    at: usize,
    /// The unreleased section whose body is absorbed, if any.
    unreleased: ?*const parse.Document.Section = null,
    /// Group text captured from `[Unreleased]`, carried over verbatim under
    /// `### <name>`.
    absorbed: []const AbsorbedGroup = &.{},

    pub const AbsorbedGroup = struct {
        name: []const u8,
        /// The group's body text without its heading line, trimmed.
        body: []const u8,
    };
};

/// Work out where the release section belongs.
///
/// - Above the newest release section, when one exists.
/// - Below the preamble, when the file has no sections yet.
/// - Never appended at the end of a file with sections: an unfamiliar file
///   would get its newest release buried under the oldest.
pub fn place(
    allocator: std.mem.Allocator,
    doc: parse.Document,
    absorb_unreleased: bool,
) Error!Placement {
    if (doc.sections.len == 0) {
        return .{ .at = doc.preamble.len };
    }
    if (doc.newestRelease()) |newest| {
        var absorbed: []const Placement.AbsorbedGroup = &.{};
        var unreleased: ?*const parse.Document.Section = null;
        if (absorb_unreleased) {
            if (doc.findUnreleased()) |u| {
                unreleased = u;
                absorbed = try absorbGroups(allocator, u.*);
            }
        }
        return .{ .at = newest.heading.start, .unreleased = unreleased, .absorbed = absorbed };
    }
    // Only `[Unreleased]` headings: insert after it.
    if (doc.findUnreleased()) |u| {
        return .{
            .at = u.heading.start + 0,
            .unreleased = if (absorb_unreleased) u else null,
            .absorbed = if (absorb_unreleased) try absorbGroups(allocator, u.*) else &.{},
        };
    }
    return error.Unparsable;
}

/// Capture the content of an unreleased section, per group.
///
/// The text is kept as written: a hand-written bullet keeps its wording,
/// because a release must not silently reword what its author wrote.
fn absorbGroups(allocator: std.mem.Allocator, section: parse.Document.Section) Error![]const Placement.AbsorbedGroup {
    var out: std.ArrayList(Placement.AbsorbedGroup) = .empty;
    errdefer out.deinit(allocator);

    if (section.groups.len == 0) {
        // Bullets directly under the heading, with no group.
        const heading_line_end = std.mem.indexOfScalar(u8, section.body, '\n') orelse section.body.len;
        const body = std.mem.trim(u8, section.body[heading_line_end..], " \t\r\n");
        if (body.len != 0) try out.append(allocator, .{ .name = "", .body = body });
        return out.toOwnedSlice(allocator);
    }
    for (section.groups) |g| {
        const heading_end = std.mem.indexOfScalarPos(u8, section.body, g.start, '\n') orelse section.body.len;
        const body = std.mem.trim(u8, section.body[heading_end..g.end], " \t\r\n");
        if (body.len != 0) try out.append(allocator, .{ .name = g.name, .body = body });
    }
    return out.toOwnedSlice(allocator);
}

/// True when a section has no content beyond its heading (placeholder like
/// `<!-- add entries here -->` counts as empty).
pub fn sectionIsEmpty(section: parse.Document.Section) bool {
    const heading_end = std.mem.indexOfScalar(u8, section.body, '\n') orelse return true;
    var it = std.mem.splitScalar(u8, section.body[heading_end..], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "<!--") and std.mem.endsWith(u8, line, "-->")) continue;
        return false;
    }
    return true;
}

pub const InsertOptions = struct {
    /// Heading text including `##`, e.g. `## [0.8.0] - 2026-11-15`.
    heading: []const u8,
    /// The rendered body under the heading (groups and bullets), no heading.
    body: []const u8,
    eol: Eol,
    /// Replace the `[Unreleased]` section body rather than inserting a version
    /// section (used by `write_mode = "replace-unreleased"`).
    replace_unreleased: bool = false,
};

/// Splice a release section into `text` at `placement`, returning the new file.
///
/// The result is normalised only around the insertion: exactly one blank line
/// separates the new section from what precedes and follows it. Bytes outside
/// that window are copied untouched.
pub fn insert(
    allocator: std.mem.Allocator,
    text: []const u8,
    placement: Placement,
    opts: InsertOptions,
) Error![]u8 {
    const eol = eolText(opts.eol);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Trim the blank/whitespace run immediately before the insertion point so
    // the spacing is rebuilt rather than doubled.
    var before = text[0..placement.at];
    while (before.len != 0) {
        const last_nl = std.mem.lastIndexOfScalar(u8, before, '\n') orelse break;
        // Only trim content that consists of blank lines at the very end.
        const tail = before[last_nl + 1 ..];
        if (std.mem.trim(u8, tail, " \t\r").len == 0) {
            before = before[0..last_nl];
            if (before.len != 0 and before[before.len - 1] == '\r') before = before[0 .. before.len - 1];
            continue;
        }
        break;
    }
    if (before.len != 0 and !std.mem.endsWith(u8, before, "\n")) {
        try out.appendSlice(allocator, before);
        try out.appendSlice(allocator, eol);
    } else {
        try out.appendSlice(allocator, before);
    }
    if (before.len != 0) try out.appendSlice(allocator, eol);

    try out.appendSlice(allocator, opts.heading);
    try out.appendSlice(allocator, eol);
    const body = std.mem.trim(u8, opts.body, " \t\r\n");
    if (body.len != 0) {
        try out.appendSlice(allocator, eol);
        // The body may be written with `\n` regardless of the file: a CRLF
        // changelog with one LF line shows a spurious change on every line of
        // the diff, so line endings are re-applied here.
        try appendWithEol(allocator, &out, body, eol);
        try out.appendSlice(allocator, eol);
    }

    const after = text[placement.at..];
    const rest = std.mem.trimStart(u8, after, " \t\r\n");
    if (rest.len != 0) {
        try out.appendSlice(allocator, eol);
        try out.appendSlice(allocator, rest);
    }
    if (!std.mem.endsWith(u8, out.items, "\n")) try out.appendSlice(allocator, eol);
    return out.toOwnedSlice(allocator);
}

/// Remove an unreleased section's *content*, keeping the heading and a blank
/// line, so the next cycle starts from a clean `[Unreleased]`.
pub fn clearUnreleased(
    allocator: std.mem.Allocator,
    text: []const u8,
    doc: parse.Document,
    eol: Eol,
) Error![]u8 {
    const u = doc.findUnreleased() orelse return allocator.dupe(u8, text);
    const heading_line_end = (std.mem.indexOfScalar(u8, u.body, '\n') orelse u.body.len);
    const heading_line = u.body[0..heading_line_end];
    // Keep any HTML comment placeholder under the heading: it is an
    // instruction to the author, not content.
    var keep: []const u8 = "";
    var it = std.mem.splitScalar(u8, u.body[heading_line_end..], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "<!--") and std.mem.endsWith(u8, line, "-->")) {
            keep = raw;
            break;
        }
        break;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const start = u.heading.start;
    const end = u.heading.start + u.body.len;
    try out.appendSlice(allocator, text[0..start]);
    try out.appendSlice(allocator, heading_line);
    try out.appendSlice(allocator, eolText(eol));
    try out.appendSlice(allocator, eolText(eol));
    if (keep.len != 0) {
        try out.appendSlice(allocator, keep);
        try out.appendSlice(allocator, eolText(eol));
        try out.appendSlice(allocator, eolText(eol));
    }
    try out.appendSlice(allocator, text[end..]);
    return out.toOwnedSlice(allocator);
}

/// Rewrite the link-reference footer for a new release.
///
/// Reference-style changelogs end with
/// `[0.7.0]: …/compare/v0.6.2...v0.7.0` and `[Unreleased]: …/compare/v0.7.0...HEAD`.
/// Inserting a section without touching these leaves `[0.8.0]` rendering as
/// literal text, so the block is updated:
///
/// - `[Unreleased]: …/compare/<new tag>...HEAD`
/// - `[<new label>]: …/compare/<previous tag>...<new tag>`
///
/// A file with no reference definitions is left alone; inventing a block in a
/// file that does not use one would be rewriting someone's style.
pub const FooterOptions = struct {
    /// The new label as written in the heading, e.g. `0.8.0`.
    new_label: []const u8,
    /// Tag name for the new release, e.g. `v0.8.0`.
    new_tag: []const u8,
    /// Tag of the previous release, e.g. `v0.7.3`, if known.
    previous_tag: ?[]const u8,
    /// Base URL without the compare path, e.g. `https://github.com/o/r`.
    /// Without it the existing definitions are rewritten by substituting the
    /// tags, which keeps unknown hosting shapes working.
    repo_url: ?[]const u8,
};

/// Returns the new trailer, or null when the file has no footer to update.
pub fn rewriteFooter(allocator: std.mem.Allocator, doc: parse.Document, opts: FooterOptions) Error!?[]u8 {
    if (!doc.reference_style or doc.refs.len == 0) return null;

    // Learn the URL shape from an existing released definition.
    var hint: ?[]const u8 = null;
    var prev_existing: ?[]const u8 = null;
    var unreleased_target: ?[]const u8 = null;
    for (doc.refs) |r| {
        if (parse.isUnreleasedLabel(r.label)) {
            unreleased_target = targetOf(r.line);
            continue;
        }
        if (hint == null) {
            hint = targetOf(r.line);
            prev_existing = r.label;
        }
    }
    const style_hint = hint orelse unreleased_target orelse "";
    const base = opts.repo_url orelse repoUrlFrom(style_hint) orelse return null;

    var url_buf: [1024]u8 = undefined;
    const release_url = try compareUrl(base, style_hint, opts.previous_tag orelse prev_existing, opts.new_tag, false, &url_buf);
    var head_buf: [1024]u8 = undefined;
    const head_url = try compareUrl(base, style_hint, opts.new_tag, opts.new_tag, true, &head_buf);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const eol = doc.eol;
    var wrote_new = false;
    for (doc.refs) |r| {
        if (std.mem.eql(u8, r.label, opts.new_label)) continue;
        if (parse.isUnreleasedLabel(r.label)) {
            try appendRefLine(allocator, &out, eol, r.label, head_url);
            try appendRefLine(allocator, &out, eol, opts.new_label, release_url);
            wrote_new = true;
            continue;
        }
        try out.appendSlice(allocator, r.line);
    }
    if (!wrote_new) {
        try appendRefLine(allocator, &out, eol, opts.new_label, release_url);
    }
    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

/// The URL part of `[label]: url`.
fn targetOf(ref_line: []const u8) ?[]const u8 {
    const close = std.mem.indexOfScalar(u8, ref_line, ']') orelse return null;
    if (close + 1 >= ref_line.len or ref_line[close + 1] != ':') return null;
    return std.mem.trim(u8, ref_line[close + 2 ..], " \t\r\n");
}

/// `https://github.com/o/r/compare/v0.1...v0.2` → `https://github.com/o/r`.
pub fn repoUrlFrom(target: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "/compare/", "/releases/tag/" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, target, m)) |i| return target[0..i];
    }
    return null;
}

fn appendRefLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), eol: []const u8, label: []const u8, target: []const u8) !void {
    try out.print(allocator, "[{s}]: {s}{s}", .{ label, target, eol });
}

/// Human-readable compare URL for a release, given what the file already does.
///
/// Three shapes are common; pick the one the existing footer uses so a
/// rewrite does not introduce a second style into one file:
///   `…/compare/<prev>...<new>`   (GitHub, GitLab)
///   `…/releases/tag/<tag>`       (GitHub release pages)
///   `…/-/compare/<prev>...<new>` (GitLab's dash form)
pub fn compareUrl(
    repo_url: []const u8,
    style_hint: ?[]const u8,
    prev_tag: ?[]const u8,
    new_tag: []const u8,
    head: bool,
    buf: []u8,
) ![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    const prev = prev_tag orelse "";
    const use_release_url = if (style_hint) |h| std.mem.indexOf(u8, h, "/releases/tag/") != null else false;
    if (use_release_url) {
        try fbs.print("{s}/releases/tag/{s}", .{ repo_url, new_tag });
        return fbs.buffered();
    }
    const dash = if (style_hint) |h| std.mem.indexOf(u8, h, "/-/compare/") != null else false;
    const to = if (head) "HEAD" else new_tag;
    try fbs.print("{s}{s}/compare/{s}...{s}", .{ repo_url, if (dash) "/-" else "", prev, to });
    return fbs.buffered();
}

test "placement goes above the newest release" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\n## [0.7.0] - 2026-01-01\n\n- x\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const p = try place(a, doc, true);
    defer a.free(p.absorbed);
    try std.testing.expectEqual(@as(usize, 13), p.at);
}

test "placement in an empty file appends after the preamble" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\nAll notable changes.\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const p = try place(a, doc, true);
    try std.testing.expectEqual(text.len, p.at);
}

test "absorption keeps hand-written bullets verbatim" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- planned: faster startup\n\n## [0.7.0]\n\n- x\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const p = try place(a, doc, true);
    defer a.free(p.absorbed);
    try std.testing.expectEqual(@as(usize, 1), p.absorbed.len);
    try std.testing.expectEqualStrings("Added", p.absorbed[0].name);
    try std.testing.expectEqualStrings("- planned: faster startup", p.absorbed[0].body);
    try std.testing.expect(p.unreleased != null);
}

test "empty unreleased section absorbs nothing" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\n## [Unreleased]\n\n<!-- entries -->\n\n## [0.7.0]\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const u = doc.findUnreleased().?;
    try std.testing.expect(sectionIsEmpty(u.*));
}

test "clearing unreleased keeps its heading and placeholder" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- one\n\n## [0.7.0]\n\n- x\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const out = try clearUnreleased(a, text, doc, .lf);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "## [Unreleased]\n\n## [0.7.0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- x") != null);
}

test "footer rewrite points at the new tag" {
    var buf: [256]u8 = undefined;
    const url = try compareUrl("https://github.com/o/r", "https://github.com/o/r/compare/v0.6.0...v0.7.0", "v0.7.3", "v0.8.0", false, &buf);
    try std.testing.expectEqualStrings("https://github.com/o/r/compare/v0.7.3...v0.8.0", url);
    const head = try compareUrl("https://github.com/o/r", null, "v0.8.0", "v0.8.0", true, &buf);
    try std.testing.expectEqualStrings("https://github.com/o/r/compare/v0.8.0...HEAD", head);
    const release = try compareUrl("https://github.com/o/r", "https://github.com/o/r/releases/tag/v0.7.0", "v0.7.0", "v0.8.0", false, &buf);
    try std.testing.expectEqualStrings("https://github.com/o/r/releases/tag/v0.8.0", release);
}

/// Append `text`, converting every `\n` (including the `\n` of a `\r\n`) to
/// `eol`.
fn appendWithEol(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, eol: []const u8) !void {
    if (std.mem.eql(u8, eol, "\n")) {
        try out.appendSlice(allocator, text);
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.appendSlice(allocator, eol);
        first = false;
        try out.appendSlice(allocator, std.mem.trimEnd(u8, line, "\r"));
    }
}

test "insert produces exactly one blank line around the section" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\nIntro line.\n\n## [0.7.0] - 2026-01-01\n\n### Added\n\n- old\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const p = try place(a, doc, true);
    const out = try insert(a, text, p, .{
        .heading = "## [0.8.0] - 2026-11-15",
        .body = "### Added\n\n- **cli:** new",
        .eol = .lf,
    });
    defer a.free(out);
    const want =
        \\# Changelog
        \\
        \\Intro line.
        \\
        \\## [0.8.0] - 2026-11-15
        \\
        \\### Added
        \\
        \\- **cli:** new
        \\
        \\## [0.7.0] - 2026-01-01
        \\
        \\### Added
        \\
        \\- old
        \\
    ;
    try std.testing.expectEqualStrings(want, out);
}

test "insert into an empty file keeps the preamble" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\nAll notable changes.\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const p = try place(a, doc, true);
    const out = try insert(a, text, p, .{ .heading = "## 1.0.0", .body = "", .eol = .lf });
    defer a.free(out);
    try std.testing.expectEqualStrings("# Changelog\n\nAll notable changes.\n\n## 1.0.0\n", out);
}

test "insert preserves CRLF" {
    const a = std.testing.allocator;
    const text = "# Changelog\r\n\r\n## [0.7.0]\r\n\r\n- old\r\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const p = try place(a, doc, true);
    const out = try insert(a, text, p, .{ .heading = "## [0.8.0]", .body = "- new", .eol = .crlf });
    defer a.free(out);
    try std.testing.expectEqualStrings("# Changelog\r\n\r\n## [0.8.0]\r\n\r\n- new\r\n\r\n## [0.7.0]\r\n\r\n- old\r\n", out);
}

test "footer rewrite replaces unreleased and adds the new release" {
    const a = std.testing.allocator;
    const text =
        "# Changelog\n\n## [0.7.3]\n\n- x\n\n[Unreleased]: https://github.com/o/r/compare/v0.7.3...HEAD\n[0.7.3]: https://github.com/o/r/compare/v0.7.0...v0.7.3\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    const trailer = (try rewriteFooter(a, doc, .{
        .new_label = "0.8.0",
        .new_tag = "v0.8.0",
        .previous_tag = "v0.7.3",
        .repo_url = null,
    })).?;
    defer a.free(trailer);
    try std.testing.expectEqualStrings(
        "[Unreleased]: https://github.com/o/r/compare/v0.8.0...HEAD\n" ++
            "[0.8.0]: https://github.com/o/r/compare/v0.7.3...v0.8.0\n" ++
            "[0.7.3]: https://github.com/o/r/compare/v0.7.0...v0.7.3\n",
        trailer,
    );
}

test "footer rewrite is a no-op without reference definitions" {
    const a = std.testing.allocator;
    const text = "# Changelog\n\n## 0.7.0\n\n- x\n";
    const doc = try parse.parse(a, text);
    defer doc.deinit(a);
    try std.testing.expect(try rewriteFooter(a, doc, .{ .new_label = "0.8.0", .new_tag = "v0.8.0", .previous_tag = null, .repo_url = null }) == null);
}

test "inserting into every fixture keeps its line endings" {
    const a = std.testing.allocator;
    const names = [_][]const u8{
        "keep-a-changelog.md",
        "bare-headings.md",
        "crlf.md",
        "no-trailing-newline.md",
        "title-only.md",
    };
    for (names) |name| {
        const path = try std.fmt.allocPrint(a, "tests/fixtures/{s}", .{name});
        defer a.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
        defer a.free(text);

        const doc = try parse.parse(a, text);
        defer doc.deinit(a);
        const placement = try place(a, doc, true);
        defer a.free(placement.absorbed);
        const out = try insert(a, text, placement, .{
            .heading = "## [9.9.9] - 2030-01-01",
            .body = "### Added\n\n- smoke",
            .eol = eolOf(doc),
        });
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "## [9.9.9] - 2030-01-01") != null);

        // A CRLF file must stay CRLF; a bare LF would show up on every line.
        if (std.mem.eql(u8, eolText(eolOf(doc)), "\r\n")) {
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, out, i, '\n')) |at| {
                try std.testing.expect(at > 0 and out[at - 1] == '\r');
                i = at + 1;
            }
        }
    }
}
