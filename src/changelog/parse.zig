//! Parsing and editing a Markdown changelog.
//!
//! The file belongs to its author: hand-written prose, comments, odd spacing,
//! CRLF, maybe no final newline. Re-rendering it from a data model would
//! rewrite all of that. So the file is split into *blocks* that carry their
//! original bytes, and every edit splices bytes in between them. `render`
//! concatenates the blocks and is byte-identical to the input until something
//! is actually inserted (`parse_render_round_trips`).
//!
//! What this module knows about:
//! - version headings: `## [1.2.3] - 2026-01-01`, `## [1.2.3]`, `## 1.2.3`,
//!   `## 1.2.3 (2026-01-01)`, and the uv-style `## 0.13.8` + `Released on …`;
//! - the unreleased heading: `## [Unreleased]` and common spellings;
//! - `### Group` subsections inside a version section;
//! - link-reference definitions at the bottom (`[1.2.3]: …/compare/…`).

const std = @import("std");

pub const Heading = struct {
    /// Byte offset of the `## ` line in the original file.
    start: usize,
    /// Byte offset just past this section (the next heading, or EOF).
    end: usize,
    /// `Unreleased`, `1.2.3`, `v1.2.3` … as written between the brackets.
    label: []const u8,
    unreleased: bool,
    /// Trailing text after the version, e.g. `- 2026-01-01` or `(2026-01-01)`.
    rest: []const u8,
    /// The heading was written as `## [label]`, so a `[label]: url` reference
    /// definition belongs with it.
    reference_style: bool,
};

pub const Document = struct {
    /// Everything before the first version heading (title, intro, comments).
    preamble: []const u8,
    sections: []Section,
    /// Everything after the last version section: link-reference definitions
    /// and anything else trailing. Replaced whole when footers change.
    trailer: []const u8,
    /// The file uses reference-style version headings (`## [1.2.3]`), which
    /// means a `[1.2.3]: url` definition is expected.
    reference_style: bool,
    /// Link-reference definitions found in the trailer, in file order.
    refs: []Ref,
    eol: []const u8,

    /// Concatenate the pieces back into a file. Equal to the input until an
    /// edit replaced one of them.
    pub fn render(self: Document, allocator: std.mem.Allocator) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, self.preamble);
        for (self.sections) |s| try out.appendSlice(allocator, s.body);
        try out.appendSlice(allocator, self.trailer);
        return out.toOwnedSlice(allocator);
    }

    /// Free the slices this document allocated. The byte slices themselves
    /// point into the source text, which the caller owns.
    pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
        for (self.sections) |s| allocator.free(s.groups);
        allocator.free(self.sections);
        allocator.free(self.refs);
    }

    pub const Section = struct {
        heading: Heading,
        /// Bytes from the heading start to the next section start.
        body: []const u8,
        /// `### Group` subsections inside the body, in order.
        groups: []Group,
    };

    pub const Group = struct {
        /// The heading text, e.g. `Added`.
        name: []const u8,
        /// Byte offset of the `### ` line, relative to the section body.
        start: usize,
        /// Byte offset just past the group (next `###`, or end of section).
        end: usize,
    };

    pub const Ref = struct {
        /// The bracketed label, e.g. `1.2.3` or `Unreleased`.
        label: []const u8,
        /// Whole line including its newline, as written.
        line: []const u8,
    };

    pub fn findUnreleased(self: Document) ?*const Section {
        for (self.sections) |*s| {
            if (s.heading.unreleased) return s;
        }
        return null;
    }

    /// The newest released section (sections are in file order, newest first).
    pub fn newestRelease(self: Document) ?*const Section {
        for (self.sections) |*s| {
            if (!s.heading.unreleased) return s;
        }
        return null;
    }

    /// Does a section with this label already exist?
    pub fn hasLabel(self: Document, label: []const u8) bool {
        for (self.sections) |s| {
            if (std.mem.eql(u8, s.heading.label, label)) return true;
        }
        return false;
    }
};

pub const ParseError = error{OutOfMemory};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Document {
    const eol: []const u8 = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";

    var headings: std.ArrayList(Heading) = .empty;
    defer headings.deinit(allocator);
    try scanHeadings(allocator, text, &headings);

    var sections: std.ArrayList(Document.Section) = .empty;
    errdefer sections.deinit(allocator);

    var preamble_end: usize = text.len;
    if (headings.items.len != 0) preamble_end = headings.items[0].start;

    // The trailer starts at the first link-reference definition that follows
    // the last section, if any; otherwise it is empty and the last section runs
    // to EOF.
    const heading_items = headings.items;
    // The trailer starts at the first link-reference definition in the last
    // section's lines. Scanning from the section's *end* would start at EOF.
    var trailer_start: usize = text.len;
    if (heading_items.len != 0) {
        const last = heading_items[heading_items.len - 1];
        trailer_start = findTrailerStart(text, last.start) orelse text.len;
    }
    const sections_end = trailer_start;

    var reference_style = false;
    for (headings.items) |h| {
        if (h.reference_style) reference_style = true;
    }

    for (headings.items, 0..) |h, i| {
        const end = if (i + 1 < headings.items.len) headings.items[i + 1].start else sections_end;
        const body = text[h.start..end];
        var groups: std.ArrayList(Document.Group) = .empty;
        errdefer groups.deinit(allocator);
        try scanGroups(allocator, body, &groups);
        try sections.append(allocator, .{
            .heading = h,
            .body = body,
            .groups = try groups.toOwnedSlice(allocator),
        });
    }

    var refs: std.ArrayList(Document.Ref) = .empty;
    errdefer refs.deinit(allocator);
    try scanRefs(allocator, text[trailer_start..], &refs);

    return .{
        .preamble = text[0..preamble_end],
        .sections = try sections.toOwnedSlice(allocator),
        .trailer = text[trailer_start..],
        .reference_style = reference_style,
        .refs = try refs.toOwnedSlice(allocator),
        .eol = eol,
    };
}

/// Section headings are level-2 (`## `). A level-3 heading is a group, and a
/// level-1 heading is the document title.
fn scanHeadings(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Heading)) ParseError!void {
    var line_start: usize = 0;
    var last: ?usize = null;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (isVersionHeading(trimmed)) |parsed| {
            if (last) |i| out.items[i].end = line_start;
            try out.append(allocator, .{
                .start = line_start,
                .end = text.len,
                .label = parsed.label,
                .unreleased = parsed.unreleased,
                .rest = parsed.rest,
                .reference_style = parsed.reference_style,
            });
            last = out.items.len - 1;
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    // The last heading runs to EOF; earlier ones were closed as they were
    // found. Leaving this implicit made `end` point past the file, so the
    // trailer scan started at EOF and reference definitions were swallowed by
    // the last section.
    if (last) |i| out.items[i].end = text.len;
}

pub const ParsedHeading = struct {
    label: []const u8,
    unreleased: bool,
    rest: []const u8,
    reference_style: bool,
};

/// Recognise a level-2 heading that names a version or the unreleased state.
/// Anything else (`## Contributing`, `## Installation`) is not a section.
pub fn isVersionHeading(trimmed_line: []const u8) ?ParsedHeading {
    if (!std.mem.startsWith(u8, trimmed_line, "## ")) return null;
    var rest = trimmed_line[3..];

    if (std.mem.startsWith(u8, rest, "[")) {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        const label = rest[1..close];
        if (!isUnreleasedLabel(label) and !looksLikeVersion(label)) return null;
        return .{
            .label = label,
            .unreleased = isUnreleasedLabel(label),
            .rest = rest[close + 1 ..],
            .reference_style = true,
        };
    }

    // Bare `## 1.2.3`, optionally with a date in parentheses or after ` - `.
    if (isUnreleasedLabel(rest)) {
        return .{ .label = std.mem.trim(u8, rest, " \t"), .unreleased = true, .rest = "", .reference_style = false };
    }
    const token_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const token = rest[0..token_end];
    if (!looksLikeVersion(token)) return null;
    return .{
        .label = token,
        .unreleased = false,
        .rest = rest[token_end..],
        .reference_style = false,
    };
}

pub fn isUnreleasedLabel(label: []const u8) bool {
    const trimmed = std.mem.trim(u8, label, " \t");
    const candidates = [_][]const u8{ "Unreleased", "unreleased", "Unreleased Changes", "Next", "TBD", "Upcoming", "Pending" };
    for (candidates) |c| {
        if (std.mem.eql(u8, trimmed, c)) return true;
    }
    return false;
}

/// Loose version shape: starts with a digit (or `v` + digit) and contains a
/// dot or is otherwise obviously a release name. Strict semver parsing happens
/// in `version/semver.zig`; this only decides "is this heading a section".
pub fn looksLikeVersion(label: []const u8) bool {
    var s = std.mem.trim(u8, label, " \t");
    if (s.len == 0) return false;
    if (s[0] == 'v' or s[0] == 'V') s = s[1..];
    if (s.len == 0) return false;
    if (!(s[0] >= '0' and s[0] <= '9')) return false;
    return true;
}

/// A `### Group` subsection. Level 4+ headings belong to the group's text.
fn scanGroups(allocator: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Document.Group)) ParseError!void {
    var line_start: usize = 0;
    while (line_start <= body.len) {
        const line_end = std.mem.indexOfScalarPos(u8, body, line_start, '\n') orelse body.len;
        const line = std.mem.trim(u8, body[line_start..line_end], " \t\r");
        if (std.mem.startsWith(u8, line, "### ")) {
            const name = std.mem.trim(u8, line[4..], " \t#");
            if (out.items.len != 0) out.items[out.items.len - 1].end = line_start;
            try out.append(allocator, .{ .name = name, .start = line_start, .end = body.len });
        }
        if (line_end == body.len) break;
        line_start = line_end + 1;
    }
}

/// The trailer begins at the first line of a run of link-reference definitions
/// (`[label]: target`) that runs to the end of the file. A run followed by
/// other content is not a footer, and returns null so nothing is rewritten.
fn findTrailerStart(text: []const u8, from: usize) ?usize {
    var line_start = from;
    var first_ref: ?usize = null;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[line_start..line_end], " \t\r");
        if (parseRefLine(line) != null) {
            if (first_ref == null) first_ref = line_start;
        } else if (first_ref != null and line.len != 0) {
            // A non-reference line after references: the references ended, so
            // they are not the trailer.
            first_ref = null;
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return first_ref;
}

fn scanRefs(allocator: std.mem.Allocator, trailer: []const u8, out: *std.ArrayList(Document.Ref)) ParseError!void {
    var line_start: usize = 0;
    while (line_start < trailer.len) {
        const line_end = std.mem.indexOfScalarPos(u8, trailer, line_start, '\n') orelse trailer.len;
        const line = trailer[line_start..line_end];
        if (parseRefLine(std.mem.trim(u8, line, " \t\r"))) |label| {
            const full_end = if (line_end < trailer.len) line_end + 1 else line_end;
            try out.append(allocator, .{ .label = label, .line = trailer[line_start..full_end] });
        }
        if (line_end == trailer.len) break;
        line_start = line_end + 1;
    }
}

/// `[label]: target` → `label`.
pub fn parseRefLine(line: []const u8) ?[]const u8 {
    if (line.len < 4 or line[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    if (close + 1 >= line.len or line[close + 1] != ':') return null;
    return line[1..close];
}

test "parses a Keep a Changelog file" {
    const a = std.testing.allocator;
    const text =
        \\# Changelog
        \\
        \\All notable changes.
        \\
        \\## [Unreleased]
        \\
        \\## [0.7.0] - 2026-11-05
        \\
        \\### Added
        \\
        \\- **cli:** a thing
        \\
        \\[Unreleased]: https://example.com/compare/v0.6.0...HEAD
        \\[0.7.0]: https://example.com/compare/v0.5.0...v0.7.0
        \\
    ;
    const doc = try parse(a, text);
    defer doc.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), doc.sections.len);
    try std.testing.expect(doc.reference_style);
    try std.testing.expect(doc.findUnreleased() != null);
    try std.testing.expectEqualStrings("0.7.0", doc.newestRelease().?.heading.label);
    try std.testing.expectEqual(@as(usize, 1), doc.sections[1].groups.len);
    try std.testing.expectEqualStrings("Added", doc.sections[1].groups[0].name);
    try std.testing.expectEqual(@as(usize, 2), doc.refs.len);
    try std.testing.expectEqualStrings("Unreleased", doc.refs[0].label);
    try std.testing.expect(std.mem.indexOf(u8, doc.trailer, "[0.7.0]:") != null);
}

test "round-trips byte for byte" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "# Changelog\n",
        "# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- x\n",
        "# Changelog\r\n\r\n## [1.0.0]\r\n\r\n- crlf line\r\n",
        // No trailing newline.
        "# Changelog\n\n## 1.0.0\n- last line without newline",
        // uv style: bare heading plus a sub-line.
        "# Changelog\n\n## 0.13.8\n\nReleased on 2026-11-12.\n\n### Python\n\n- thing\n",
        // A title section that is not a version must not be treated as one.
        "# Changelog\n\n## Contributing\n\nSee CONTRIBUTING.md\n",
    };
    for (cases) |text| {
        const doc = try parse(a, text);
        defer doc.deinit(a);
        const rendered = try doc.render(a);
        defer a.free(rendered);
        try std.testing.expectEqualStrings(text, rendered);
    }
}

test "recognises heading spellings" {
    try std.testing.expect(isVersionHeading("## [1.2.3] - 2026-01-01") != null);
    try std.testing.expectEqualStrings("1.2.3", isVersionHeading("## [1.2.3]").?.label);
    try std.testing.expectEqualStrings("1.2.3", isVersionHeading("## 1.2.3").?.label);
    try std.testing.expectEqualStrings("1.2.3", isVersionHeading("## 1.2.3 (2026-01-01)").?.label);
    try std.testing.expectEqualStrings("v1.2.3", isVersionHeading("## v1.2.3").?.label);
    try std.testing.expect(isVersionHeading("## [Unreleased]").?.unreleased);
    try std.testing.expect(isVersionHeading("## Unreleased").?.unreleased);
    try std.testing.expect(isVersionHeading("## Contributing") == null);
    try std.testing.expect(isVersionHeading("### Added") == null);
    try std.testing.expect(isVersionHeading("# Title") == null);
}

// ------------------------------------------------------------- fixtures
//
// Real-world changelogs committed under tests/fixtures. The editor's promise
// is that it never rewrites what it did not touch, so parsing and re-rendering
// each of these must be byte-identical — CRLF, missing trailing newlines and
// all.

const fixture_names = [_][]const u8{
    "keep-a-changelog.md",
    "bare-headings.md",
    "crlf.md",
    "no-trailing-newline.md",
    "title-only.md",
};

test "every fixture round-trips byte for byte" {
    const a = std.testing.allocator;
    for (fixture_names) |name| {
        const path = try std.fmt.allocPrint(a, "tests/fixtures/{s}", .{name});
        defer a.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
        defer a.free(text);

        const doc = try parse(a, text);
        defer doc.deinit(a);
        const rendered = try doc.render(a);
        defer a.free(rendered);
        try std.testing.expectEqualStrings(text, rendered);
    }
}

test "the detected sections of the fixtures are the ones a human would name" {
    const a = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/keep-a-changelog.md", a, .limited(1 << 20));
    defer a.free(text);
    const doc = try parse(a, text);
    defer doc.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), doc.sections.len);
    try std.testing.expect(doc.findUnreleased() != null);
    try std.testing.expectEqualStrings("1.2.0", doc.newestRelease().?.heading.label);
    try std.testing.expectEqual(@as(usize, 3), doc.refs.len);

    const bare = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/bare-headings.md", a, .limited(1 << 20));
    defer a.free(bare);
    const bdoc = try parse(a, bare);
    defer bdoc.deinit(a);
    // `Released on 2026-11-12.` must not be mistaken for a section.
    try std.testing.expectEqual(@as(usize, 2), bdoc.sections.len);
    try std.testing.expectEqualStrings("0.13.8", bdoc.newestRelease().?.heading.label);
}
