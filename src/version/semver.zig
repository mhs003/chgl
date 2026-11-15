//! Semantic versions: parsing, ordering, and the bump rules.
//!
//! Only the subset the tool needs: `MAJOR.MINOR.PATCH` with an optional
//! prerelease and build metadata, plus the prefix/suffix forms that real tags
//! use (`v1.2.3`, `release-1.2.3`, `pkg-v1.2.3`).

const std = @import("std");

pub const Semver = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: []const u8 = "",
    build: []const u8 = "",

    pub fn parse(text: []const u8) ?Semver {
        var s = text;
        // Build metadata is not part of ordering; keep it, ignore it after.
        var build: []const u8 = "";
        if (std.mem.indexOfScalar(u8, s, '+')) |i| {
            build = s[i + 1 ..];
            s = s[0..i];
        }
        var prerelease: []const u8 = "";
        if (std.mem.indexOfScalar(u8, s, '-')) |i| {
            prerelease = s[i + 1 ..];
            s = s[0..i];
        }
        var it = std.mem.splitScalar(u8, s, '.');
        const major = parseNum(it.next() orelse return null) orelse return null;
        const minor = parseNum(it.next() orelse return null) orelse return null;
        const patch = parseNum(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null;
        return .{ .major = major, .minor = minor, .patch = patch, .prerelease = prerelease, .build = build };
    }

    fn parseNum(s: []const u8) ?u32 {
        if (s.len == 0) return null;
        // No sign, no leading zeros (strictly semver), no spaces.
        if (s[0] == '+' or s[0] == '-') return null;
        if (s.len > 1 and s[0] == '0') return null;
        return std.fmt.parseInt(u32, s, 10) catch null;
    }

    pub fn order(a: Semver, b: Semver) std.math.Order {
        if (a.major != b.major) return cmpInt(a.major, b.major);
        if (a.minor != b.minor) return cmpInt(a.minor, b.minor);
        if (a.patch != b.patch) return cmpInt(a.patch, b.patch);
        // A prerelease sorts before the release.
        if (a.prerelease.len == 0 and b.prerelease.len == 0) return .eq;
        if (a.prerelease.len == 0) return .gt;
        if (b.prerelease.len == 0) return .lt;
        return cmpPrerelease(a.prerelease, b.prerelease);
    }

    pub fn isPrerelease(self: Semver) bool {
        return self.prerelease.len != 0;
    }

    pub fn lessThan(_: void, a: Semver, b: Semver) bool {
        return order(a, b) == .lt;
    }

    /// Number of bytes needed for the longest possible rendering.
    pub fn render(self: Semver, buf: []u8) ![]const u8 {
        var fbs = std.Io.Writer.fixed(buf);
        try self.renderTo(&fbs);
        return fbs.buffered();
    }

    pub fn renderTo(self: Semver, w: *std.Io.Writer) !void {
        try w.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.prerelease.len != 0) try w.print("-{s}", .{self.prerelease});
    }
};

fn cmpInt(a: u32, b: u32) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn cmpPrerelease(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const xa = ia.next();
        const xb = ib.next();
        if (xa == null and xb == null) return .eq;
        if (xa == null) return .lt;
        if (xb == null) return .gt;
        const xa_v = xa.?;
        const xb_v = xb.?;
        const na = std.fmt.parseInt(u64, xa_v, 10) catch null;
        const nb = std.fmt.parseInt(u64, xb_v, 10) catch null;
        if (na != null and nb != null) {
            switch (cmpInt64(na.?, nb.?)) {
                .lt => return .lt,
                .gt => return .gt,
                .eq => {},
            }
            continue;
        }
        // Numeric identifiers always sort below alphanumeric ones.
        if (na != null) return .lt;
        if (nb != null) return .gt;
        switch (std.mem.order(u8, xa_v, xb_v)) {
            .lt => return .lt,
            .gt => return .gt,
            .eq => {},
        }
    }
}

fn cmpInt64(a: u64, b: u64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

/// How a tag or a `--as` value is spelled relative to the bare version.
pub const TagStyle = struct {
    prefix: []const u8 = "v",
    suffix: []const u8 = "",
};

/// Parse `text` as a version under this style.
///
/// A prefix is a claim about spelling, not a requirement: `parseWithStyle` also
/// accepts the bare form, because repositories mix `v1.2.3` and `1.2.3` and a
/// style that only ever matches one of them silently loses tags.
pub fn parseWithStyle(style: TagStyle, text: []const u8) ?Semver {
    var s = text;
    if (style.prefix.len != 0 and std.mem.startsWith(u8, s, style.prefix)) {
        s = s[style.prefix.len..];
    }
    if (style.suffix.len != 0 and std.mem.endsWith(u8, s, style.suffix)) {
        s = s[0 .. s.len - style.suffix.len];
    }
    return Semver.parse(s);
}

/// Render `v` as a tag in `style`. The buffer must be independent of any
/// caller-owned slice: writing the version into `buf[prefix.len..]` and then
/// writing the prefix would alias the writer's own buffer.
pub fn formatTag(style: TagStyle, v: Semver, buf: []u8) ![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    try fbs.writeAll(style.prefix);
    try v.renderTo(&fbs);
    try fbs.writeAll(style.suffix);
    return fbs.buffered();
}

/// Infer the prefix from newline-separated tag names by majority vote. A bare
/// version tag and a `v`-prefixed one both establish their own style; ties go
/// to `v`, which is what most repositories mean by `1.2.3` appearing once by
/// accident.
pub fn inferStyle(names: []const u8) TagStyle {
    var v_prefixed: usize = 0;
    var bare: usize = 0;
    var lines = std.mem.splitScalar(u8, names, '\n');
    while (lines.next()) |t| {
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "v") and Semver.parse(t[1..]) != null) {
            v_prefixed += 1;
        } else if (Semver.parse(t) != null) {
            bare += 1;
        }
    }
    if (bare > v_prefixed) return .{ .prefix = "" };
    return .{ .prefix = "v" };
}

pub const Bump = enum { major, minor, patch };

/// The version a set of entries implies, given the current one.
///
/// `fix`/`perf`/`refactor`/`revert` → patch, `feat` → minor, a breaking change
/// → major. Below 1.0 a breaking change bumps the minor instead, because
/// `0.x` is where the stabilisation happens and a 0.x major bump says
/// "unstable again" one release after leaving 0. (Prometheus pushes through
/// the breaking change; env-var style, not semver's.)
pub fn bumpFor(current: Semver, breaking: bool, feature: bool) Bump {
    if (breaking) {
        if (current.major == 0) return .minor;
        return .major;
    }
    if (feature) return .minor;
    return .patch;
}

pub fn apply(current: Semver, b: Bump) Semver {
    return switch (b) {
        .major => .{ .major = current.major + 1, .minor = 0, .patch = 0 },
        .minor => .{ .major = current.major, .minor = current.minor + 1, .patch = 0 },
        .patch => .{ .major = current.major, .minor = current.minor, .patch = current.patch + 1 },
    };
}

test "parse plain and prefixed" {
    const v = Semver.parse("1.2.3").?;
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
    // The prefix is optional at parse time; `formatTag` decides spelling.
    try std.testing.expect(parseWithStyle(.{}, "v1.2.3") != null);
    try std.testing.expect(parseWithStyle(.{ .prefix = "" }, "1.2.3") != null);
    try std.testing.expect(parseWithStyle(.{ .prefix = "release-" }, "release-1.2.3") != null);
    try std.testing.expect(parseWithStyle(.{ .prefix = "release-" }, "1.2.3") != null);
    try std.testing.expect(parseWithStyle(.{ .prefix = "v" }, "latest") == null);
}

test "rejects malformed" {
    for ([_][]const u8{ "", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "v1.2.3" }) |bad| {
        try std.testing.expect(Semver.parse(bad) == null);
    }
}

test "ordering" {
    try std.testing.expectEqual(std.math.Order.lt, Semver.order(Semver.parse("1.0.0").?, Semver.parse("1.0.1").?));
    try std.testing.expectEqual(std.math.Order.lt, Semver.order(Semver.parse("1.0.0-alpha").?, Semver.parse("1.0.0").?));
    try std.testing.expectEqual(std.math.Order.lt, Semver.order(Semver.parse("1.0.0-alpha.1").?, Semver.parse("1.0.0-alpha.2").?));
    try std.testing.expectEqual(std.math.Order.lt, Semver.order(Semver.parse("1.0.0-2").?, Semver.parse("1.0.0-10").?));
    try std.testing.expectEqual(std.math.Order.gt, Semver.order(Semver.parse("1.0.0-alpha").?, Semver.parse("1.0.0-1").?));
    try std.testing.expectEqual(std.math.Order.lt, Semver.order(Semver.parse("1.0.0-alpha").?, Semver.parse("1.0.0-beta").?));
    try std.testing.expectEqual(std.math.Order.eq, Semver.order(Semver.parse("1.0.0+a").?, Semver.parse("1.0.0+b").?));
}

test "bumps" {
    const at0 = Semver.parse("0.7.3").?;
    try std.testing.expectEqual(Bump.patch, bumpFor(at0, false, false));
    try std.testing.expectEqual(Bump.minor, bumpFor(at0, false, true));
    try std.testing.expectEqual(Bump.minor, bumpFor(at0, true, false));

    const at1 = Semver.parse("1.2.3").?;
    try std.testing.expectEqual(Bump.major, bumpFor(at1, true, false));

    const next = apply(at0, .minor);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.8.0", try next.render(&buf));
}

test "style inference" {
    try std.testing.expectEqualStrings("v", inferStyle("v0.1.0\nv0.2.0\nlatest\n").prefix);
    try std.testing.expectEqualStrings("", inferStyle("0.1.0\n0.2.0\nnightly").prefix);
    try std.testing.expectEqualStrings("v", inferStyle("").prefix);
    // A single accidental bare tag does not flip an established `v` history.
    try std.testing.expectEqualStrings("v", inferStyle("v1.0.0\nv1.1.0\n1.2.0\n").prefix);
}

test "format tag" {
    var buf: [32]u8 = undefined;
    const v = Semver.parse("1.2.3-rc.1").?;
    try std.testing.expectEqualStrings("v1.2.3-rc.1", try formatTag(.{ .prefix = "v" }, v, &buf));
}
