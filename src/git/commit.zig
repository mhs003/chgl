//! Conventional Commits parsing.
//!
//! The grammar is small enough to parse by hand: `type(scope)!: description`
//! with optional `BREAKING CHANGE:` footers in the body. Anything that does not
//! match is kept as `unparsed` rather than discarded — a changelog that silently
//! drops commits is worse than one with an "Other" section.

const std = @import("std");

pub const Kind = enum {
    feat,
    fix,
    perf,
    refactor,
    revert,
    docs,
    chore,
    ci,
    @"test",
    style,
    build,
    /// A `type:` this tool does not know, e.g. `deps:` or `feat2:`.
    other,
    /// Not Conventional Commits at all.
    unparsed,

    pub fn fromName(name: []const u8) Kind {
        if (std.mem.eql(u8, name, "feat")) return .feat;
        if (std.mem.eql(u8, name, "fix")) return .fix;
        if (std.mem.eql(u8, name, "perf")) return .perf;
        if (std.mem.eql(u8, name, "refactor")) return .refactor;
        if (std.mem.eql(u8, name, "revert")) return .revert;
        if (std.mem.eql(u8, name, "docs")) return .docs;
        if (std.mem.eql(u8, name, "chore")) return .chore;
        if (std.mem.eql(u8, name, "ci")) return .ci;
        if (std.mem.eql(u8, name, "test")) return .@"test";
        if (std.mem.eql(u8, name, "style")) return .style;
        if (std.mem.eql(u8, name, "build")) return .build;
        return .other;
    }

    /// Whether this kind justifies a release on its own.
    ///
    /// Mirrors the reference project's release script so the two tools cannot
    /// disagree about the same history.
    pub fn releasable(self: Kind) bool {
        return switch (self) {
            .feat, .fix, .perf, .refactor, .revert => true,
            .docs, .chore, .ci, .@"test", .style, .build, .other, .unparsed => false,
        };
    }
};

pub const Parsed = struct {
    kind: Kind,
    type_name: []const u8,
    scope: ?[]const u8,
    description: []const u8,
    breaking: bool,
    /// The text after `BREAKING CHANGE:`, if the footer was present.
    breaking_note: ?[]const u8,
    /// Issue/PR references found in the subject, e.g. `#42`.
    refs: []const []const u8,

    /// Well-formed Conventional Commits header, whether or not this tool knows
    /// the type. `deps: bump serde` is conventional; `updated the readme` is not.
    pub fn isConventional(self: Parsed) bool {
        return self.kind != .unparsed;
    }
};

pub const ParseError = error{OutOfMemory};

/// Parse `subject` (the first line) with `body` (the rest, may be empty).
/// `refs` borrows from `allocator` and must be freed by the caller via
/// `Result.deinit`, or ignored if the caller keeps the subject alive forever.
pub fn parse(allocator: std.mem.Allocator, subject: []const u8, body: []const u8) ParseError!Result {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer refs.deinit(allocator);
    try collectRefs(allocator, subject, &refs);

    const trimmed = std.mem.trimEnd(u8, subject, " \t\r");
    const head = parseHeader(trimmed);
    // Every kept slice is copied into `allocator`. Borrowing from `subject`
    // looked free but was not: callers hand in slices of a log buffer that is
    // freed as soon as the commits are consumed, and a plan outlives that.
    const type_name = if (head) |h| h.type_name else "";
    const scope = if (head) |h| h.scope else null;
    const description = if (head) |h| h.description else trimmed;
    const breaking_note = if (head != null) findBreakingNote(body) else null;

    return .{
        .owned_refs = try refs.toOwnedSlice(allocator),
        .parsed = .{
            .kind = if (head) |h| Kind.fromName(h.type_name) else .unparsed,
            .type_name = try allocator.dupe(u8, type_name),
            .scope = if (scope) |sc| try allocator.dupe(u8, sc) else null,
            .description = try allocator.dupe(u8, description),
            .breaking = if (head) |h| h.bang or breaking_note != null else breaking_note != null,
            .breaking_note = if (breaking_note) |bn| try allocator.dupe(u8, bn) else null,
            .refs = refs.items,
        },
    };
}

pub const Result = struct {
    parsed: Parsed,
    owned_refs: []const []const u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.owned_refs);
        allocator.free(self.parsed.type_name);
        if (self.parsed.scope) |s| allocator.free(s);
        allocator.free(self.parsed.description);
        if (self.parsed.breaking_note) |b| allocator.free(b);
    }

    /// Take the parsed pieces, leaving the `Result` not owning them anymore.
    pub fn takeParsed(self: *Result) Parsed {
        const p = self.parsed;
        self.parsed.type_name = "";
        self.parsed.scope = null;
        self.parsed.description = "";
        self.parsed.breaking_note = null;
        self.parsed.refs = &.{};
        self.owned_refs = &.{};
        return p;
    }
};

const Header = struct {
    type_name: []const u8,
    scope: ?[]const u8,
    description: []const u8,
    bang: bool,
};

/// `type(scope)!: description`, or `type!: description`.
fn parseHeader(s: []const u8) ?Header {
    const colon = std.mem.indexOf(u8, s, ":") orelse return null;
    var head = s[0..colon];
    const description = std.mem.trimStart(u8, s[colon + 1 ..], " ");
    if (description.len == 0) return null;

    var bang = false;
    if (head.len > 0 and head[head.len - 1] == '!') {
        bang = true;
        head = head[0 .. head.len - 1];
    }

    var scope: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, head, '(')) |open| {
        if (!std.mem.endsWith(u8, head, ")")) return null;
        scope = head[open + 1 .. head.len - 1];
        head = head[0..open];
    }
    if (head.len == 0 or !isTypeName(head)) return null;

    return .{ .type_name = head, .scope = scope, .description = description, .bang = bang };
}

/// Lowercase ASCII letters only: `feat`, `fix`. A subject like
/// `Merge branch 'x'` has no `:`-free prefix, and `Note: this` is not a type.
fn isTypeName(s: []const u8) bool {
    for (s) |c| {
        if (!(c >= 'a' and c <= 'z')) return false;
    }
    return true;
}

/// `BREAKING CHANGE: ...` anywhere in the body (also the legacy hyphen form).
pub fn findBreakingNote(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const rest = if (std.mem.startsWith(u8, trimmed, "BREAKING CHANGE:"))
            trimmed["BREAKING CHANGE:".len..]
        else if (std.mem.startsWith(u8, trimmed, "BREAKING-CHANGE:"))
            trimmed["BREAKING-CHANGE:".len..]
        else
            continue;
        const note = std.mem.trim(u8, rest, " \t\r");
        if (note.len != 0) return note;
    }
    return null;
}

/// Find `#123` references in a subject, in order, without duplicates.
fn collectRefs(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) ParseError!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '#') continue;
        var j = i + 1;
        while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
        if (j == i + 1) continue;
        const ref = text[i..j];
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, ref)) seen = true;
        }
        if (!seen) try out.append(allocator, ref);
        i = j - 1;
    }
}

test "parses plain conventional types" {
    const a = std.testing.allocator;
    {
        const r = try parse(a, "feat: add a thing", "");
        defer r.deinit(a);
        try std.testing.expectEqual(Kind.feat, r.parsed.kind);
        try std.testing.expectEqualStrings("add a thing", r.parsed.description);
        try std.testing.expect(r.parsed.scope == null);
        try std.testing.expect(!r.parsed.breaking);
    }
    {
        const r = try parse(a, "fix(parser): stop trimming leading text", "");
        defer r.deinit(a);
        try std.testing.expectEqual(Kind.fix, r.parsed.kind);
        try std.testing.expectEqualStrings("parser", r.parsed.scope.?);
        try std.testing.expectEqualStrings("stop trimming leading text", r.parsed.description);
    }
}

test "bang marks breaking at any type" {
    const a = std.testing.allocator;
    const r = try parse(a, "refactor(core)!: replace the store", "");
    defer r.deinit(a);
    try std.testing.expect(r.parsed.breaking);
    try std.testing.expectEqual(Kind.refactor, r.parsed.kind);
    try std.testing.expectEqualStrings("core", r.parsed.scope.?);

    const a2 = try parse(a, "feat!: drop python 2", "");
    defer a2.deinit(a);
    try std.testing.expect(a2.parsed.breaking);
    try std.testing.expect(a2.parsed.scope == null);
}

test "BREAKING CHANGE footer marks breaking" {
    const a = std.testing.allocator;
    const body = "Reflow things.\n\nBREAKING CHANGE: the config format changed\nmore text";
    const r = try parse(a, "chore: rework config", body);
    defer r.deinit(a);
    try std.testing.expect(r.parsed.breaking);
    try std.testing.expectEqualStrings("the config format changed", r.parsed.breaking_note.?);

    const h = try parse(a, "refactor: x", "BREAKING-CHANGE: hyphen form");
    defer h.deinit(a);
    try std.testing.expectEqualStrings("hyphen form", h.parsed.breaking_note.?);
}

test "unknown type is Other, not unparsed" {
    const a = std.testing.allocator;
    const r = try parse(a, "deps: bump serde", "");
    defer r.deinit(a);
    try std.testing.expectEqual(Kind.other, r.parsed.kind);
    try std.testing.expect(r.parsed.isConventional());
    try std.testing.expect(!r.parsed.kind.releasable());
}

test "non-conventional subjects are kept, not dropped" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "updated the readme", "WIP", "Merge branch 'feat/x' into main", "Fixed stuff.", "Note: not a type" }) |s| {
        const r = try parse(a, s, "");
        defer r.deinit(a);
        try std.testing.expectEqual(Kind.unparsed, r.parsed.kind);
        try std.testing.expectEqualStrings(s, r.parsed.description);
    }
}

test "malformed headers fall back to unparsed" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "feat:", "feat: ", "feat(scope: x", "Feat: x", "fe at: x", ":x" }) |s| {
        const r = try parse(a, s, "");
        defer r.deinit(a);
        try std.testing.expectEqual(Kind.unparsed, r.parsed.kind);
    }
}

test "issue refs are collected once" {
    const a = std.testing.allocator;
    const r = try parse(a, "fix: handle empty input (#42) refs #42 and #7", "");
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), r.owned_refs.len);
    try std.testing.expectEqualStrings("#42", r.owned_refs[0]);
    try std.testing.expectEqualStrings("#7", r.owned_refs[1]);
}

test "releasable set matches the reference release script" {
    try std.testing.expect(Kind.feat.releasable());
    try std.testing.expect(Kind.fix.releasable());
    try std.testing.expect(Kind.perf.releasable());
    try std.testing.expect(Kind.refactor.releasable());
    try std.testing.expect(Kind.revert.releasable());
    try std.testing.expect(!Kind.docs.releasable());
    try std.testing.expect(!Kind.chore.releasable());
    try std.testing.expect(!Kind.ci.releasable());
    try std.testing.expect(!Kind.@"test".releasable());
    try std.testing.expect(!Kind.style.releasable());
    try std.testing.expect(!Kind.build.releasable());
    try std.testing.expect(!Kind.unparsed.releasable());
}
