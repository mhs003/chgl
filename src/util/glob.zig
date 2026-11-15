//! Glob matching for `--exclude` and `[changelog] exclude`.
//!
//! Deliberately not regex: Zig's std has none, a hand-written matcher is a
//! liability, and `chore(release):*` is easier to write correctly than
//! `^chore\(release\):`. Supported: `*` (any run, including `/`), `?` (one
//! byte), `[abc]`/`[a-z]`/`[!a-z]`, and `{a,b}` alternatives (nested).
//!
//! Matching is anchored: the whole text must match the whole pattern.

const std = @import("std");

/// Recursion budget. Globs are tiny; this only guards against a pathological
/// pattern turning `*` backtracking into exponential work.
const MAX_DEPTH: u32 = 64;

pub fn matches(pattern: []const u8, text: []const u8) bool {
    return matchFrom(pattern, 0, text, 0, 0);
}

fn matchFrom(p: []const u8, pi0: usize, t: []const u8, ti0: usize, depth: u32) bool {
    if (depth > MAX_DEPTH) return false;
    var pi = pi0;
    var ti = ti0;

    while (pi < p.len) {
        switch (p[pi]) {
            '*' => {
                // Collapse runs of `*`, then try every suffix length.
                while (pi < p.len and p[pi] == '*') pi += 1;
                if (pi == p.len) return true;
                var i = ti;
                while (i <= t.len) : (i += 1) {
                    if (matchFrom(p, pi, t, i, depth + 1)) return true;
                }
                return false;
            },
            '?' => {
                if (ti >= t.len) return false;
                ti += 1;
                pi += 1;
            },
            '[' => {
                // An unterminated `[` is a literal, not a failure: commit
                // subjects contain brackets.
                const end = std.mem.indexOfScalarPos(u8, p, pi + 1, ']') orelse {
                    if (ti >= t.len or t[ti] != '[') return false;
                    ti += 1;
                    pi += 1;
                    continue;
                };
                if (ti >= t.len) return false;
                if (!charClass(p[pi + 1 .. end], t[ti])) return false;
                ti += 1;
                pi = end + 1;
            },
            '{' => {
                const close = matchingBrace(p, pi) orelse {
                    if (ti >= t.len or t[ti] != '{') return false;
                    ti += 1;
                    pi += 1;
                    continue;
                };
                const body = p[pi + 1 .. close];
                const rest = p[close + 1 ..];
                var it = GroupAlternatives.init(body);
                while (it.next()) |alternative| {
                    // Expand the alternative in place of the group, so nesting
                    // works without copying the pattern.
                    if (matchExpanded(alternative, rest, t[ti..], depth + 1)) return true;
                }
                return false;
            },
            '\\' => {
                // Escaped literal, so `\*` can mean a star.
                if (pi + 1 >= p.len) return false;
                if (ti >= t.len or t[ti] != p[pi + 1]) return false;
                ti += 1;
                pi += 2;
            },
            else => {
                if (ti >= t.len or t[ti] != p[pi]) return false;
                ti += 1;
                pi += 1;
            },
        }
    }
    return ti == t.len;
}

/// Match `alternative` followed by `rest` against `text`, as if the group
/// `{alternative}` (and anything after it) were the rest of the pattern.
///
/// `alternative` may itself contain groups, which is why the pieces are joined
/// into a buffer and re-entered through the normal matcher: trying split points
/// would let `c{d,e}` match `c` and leave `{d,e}` to a later position, which is
/// not how globs work.
fn matchExpanded(a: []const u8, b: []const u8, text: []const u8, depth: u32) bool {
    var buf: [512]u8 = undefined;
    const total = a.len + b.len;
    if (total > buf.len) return false;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return matchFrom(buf[0..total], 0, text, 0, depth);
}

/// Iterate the comma-separated alternatives of a `{...}` body, treating commas
/// inside nested braces as part of the nested group rather than separators.
const GroupAlternatives = struct {
    body: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn init(body: []const u8) GroupAlternatives {
        return .{ .body = body };
    }

    fn next(self: *GroupAlternatives) ?[]const u8 {
        if (self.done) return null;
        const start = self.pos;
        var depth: usize = 0;
        var i = self.pos;
        while (i < self.body.len) : (i += 1) {
            switch (self.body[i]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                ',' => if (depth == 0) {
                    self.pos = i + 1;
                    return self.body[start..i];
                },
                else => {},
            }
        }
        self.done = true;
        return self.body[start..];
    }
};

fn matchingBrace(p: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < p.len) : (i += 1) {
        switch (p[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn charClass(class: []const u8, c: u8) bool {
    var i: usize = 0;
    var negate = false;
    if (i < class.len and (class[i] == '!' or class[i] == '^')) {
        negate = true;
        i += 1;
    }
    var hit = false;
    while (i < class.len) {
        if (i + 2 < class.len and class[i + 1] == '-' and class[i + 2] != ']') {
            if (c >= class[i] and c <= class[i + 2]) hit = true;
            i += 3;
        } else {
            if (class[i] == c) hit = true;
            i += 1;
        }
    }
    return hit != negate;
}

test "literal match is anchored" {
    try std.testing.expect(matches("fix", "fix"));
    try std.testing.expect(!matches("fix", "prefix"));
    try std.testing.expect(!matches("fix", "fixes"));
}

test "star matches any run" {
    try std.testing.expect(matches("chore(release):*", "chore(release): v0.7.4"));
    try std.testing.expect(matches("*", ""));
    try std.testing.expect(matches("*", "anything at all"));
    try std.testing.expect(!matches("chore*", "feat: nope"));
}

test "question mark matches one byte" {
    try std.testing.expect(matches("v?.?.?", "v1.2.3"));
    try std.testing.expect(!matches("v?.?.?", "v10.2.3"));
}

test "character classes" {
    try std.testing.expect(matches("[0-9]*", "42 things"));
    try std.testing.expect(!matches("[0-9]*", "x42"));
    try std.testing.expect(matches("Merge branch '[a-z]*'", "Merge branch 'feat/x'"));
    try std.testing.expect(!matches("Merge branch '[!a-z]*'", "Merge branch 'feat/x'"));
    // An unterminated class is a literal, because subjects contain brackets.
    try std.testing.expect(matches("fix [WIP", "fix [WIP"));
}

test "alternatives" {
    try std.testing.expect(matches("{feat,fix}:*", "fix: a bug"));
    try std.testing.expect(matches("{feat,fix}:*", "feat: a thing"));
    try std.testing.expect(!matches("{feat,fix}:*", "docs: a thing"));
    // A group with one alternative still expands its inner group.
    try std.testing.expect(matches("a{c{d,e}}f", "acef"));
    try std.testing.expect(matches("a{c{d,e}}f", "acdf"));
    try std.testing.expect(!matches("a{c{d,e}}f", "adf"));
    try std.testing.expect(!matches("a{c{d,e}}f", "abf"));
}

test "escapes are literal" {
    try std.testing.expect(matches("a\\*b", "a*b"));
    try std.testing.expect(!matches("a\\*b", "axb"));
}

test "pathological nesting terminates" {
    const deep = "{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}";
    _ = matches(deep, "aaaaaaaaaaaaaaaaaaa");
}
