//! Where a project's version lives, and how to read (and optionally write) it.
//!
//! `chgl` never guesses a version out of thin air: without a source it writes
//! an `[Unreleased]` heading and says so. The writers touch exactly one line
//! (or one JSON value) and leave formatting alone — reformatting a user's
//! `Cargo.toml` would show up in their diff as noise.

const std = @import("std");
const semver = @import("../version/semver.zig");

pub const Kind = enum {
    cargo,
    npm,
    pyproject,
    file,

    pub fn filename(self: Kind) []const u8 {
        return switch (self) {
            .cargo => "Cargo.toml",
            .npm => "package.json",
            .pyproject => "pyproject.toml",
            .file => "VERSION",
        };
    }
};

pub const Source = struct {
    kind: Kind,
    /// Path as found, so a custom `[version] path` is reported correctly.
    path: []const u8,
    version: []const u8,
    parsed: semver.Semver,
};

pub const Error = error{ OutOfMemory, NotFound, Malformed };

/// Read the version from `text`, according to `kind`.
pub fn readFrom(kind: Kind, text: []const u8) Error![]const u8 {
    return switch (kind) {
        .cargo => try readTomlVersion(text, true),
        .pyproject => try readTomlVersion(text, false),
        .npm => try readJsonVersion(text),
        .file => blk: {
            const trimmed = std.mem.trim(u8, text, " \t\r\n\"'");
            if (trimmed.len == 0) break :blk error.Malformed;
            break :blk trimmed;
        },
    };
}

/// `[package] version = "x"` (Cargo) or `[project]` / `[tool.poetry]` (PEP 621
/// and poetry). Deliberately a line scan, not a TOML parse: the goal is the one
/// value, not to reimplement Cargo's manifest.
fn readTomlVersion(text: []const u8, cargo: bool) Error![]const u8 {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
            section = std.mem.trim(u8, line[1..close], " \t");
            continue;
        }
        const matches_section = if (cargo)
            std.mem.eql(u8, section, "package")
        else
            std.mem.eql(u8, section, "project") or std.mem.eql(u8, section, "tool.poetry");
        if (!matches_section) continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (!std.mem.eql(u8, key, "version")) continue;
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            return unquote(value);
        }
    }
    return error.NotFound;
}

fn readJsonVersion(text: []const u8) Error![]const u8 {
    // `"version": "1.2.3"` — scan for the first top-level occurrence. A full
    // JSON parse would allocate for one string; this cannot.
    const key = "\"version\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, key)) |at| {
        var j = at + key.len;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
        if (j >= text.len or text[j] != ':') {
            i = at + key.len;
            continue;
        }
        j += 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
        if (j >= text.len or text[j] != '"') return error.Malformed;
        const start = j + 1;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return error.Malformed;
        if (end == start) return error.Malformed;
        return text[start..end];
    }
    return error.NotFound;
}

fn unquote(value: []const u8) Error![]const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const inner = value[1 .. value.len - 1];
        if (inner.len == 0) return error.Malformed;
        return inner;
    }
    return error.Malformed;
}

/// Rewrite the version in `text`, returning a new buffer. Only the matching
/// line/value changes; every other byte is preserved.
pub fn writeInto(allocator: std.mem.Allocator, kind: Kind, text: []const u8, new_version: []const u8) Error![]u8 {
    switch (kind) {
        .file => return std.fmt.allocPrint(allocator, "{s}\n", .{new_version}) catch error.OutOfMemory,
        .npm => {
            const old = try readJsonVersion(text);
            const at = std.mem.indexOf(u8, text, old) orelse return error.Malformed;
            // The quotes are already in the text; replace the inner value only.
            return finishRaw(allocator, text, at, old.len, new_version);
        },
        .cargo, .pyproject => {
            const section = if (kind == .cargo) "[package]" else "[project]";
            const old = try readTomlVersion(text, kind == .cargo);
            const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{old}) catch return error.OutOfMemory;
            defer allocator.free(quoted);
            // Search after the section heading so a `version = "…"` in
            // `[dependencies]` is never the one rewritten.
            const sec = std.mem.indexOf(u8, text, section) orelse return error.Malformed;
            const at = std.mem.indexOfPos(u8, text, sec, quoted) orelse return error.Malformed;
            return finish(allocator, text, at, quoted.len, new_version);
        },
    }
}

/// Replace `old_len` bytes at `at` with `"<new_version>"`.
fn finish(allocator: std.mem.Allocator, text: []const u8, at: usize, old_len: usize, new_version: []const u8) Error![]u8 {
    const replacement = std.fmt.allocPrint(allocator, "\"{s}\"", .{new_version}) catch return error.OutOfMemory;
    defer allocator.free(replacement);
    return finishRaw(allocator, text, at, old_len, replacement);
}

fn finishRaw(allocator: std.mem.Allocator, text: []const u8, at: usize, old_len: usize, replacement: []const u8) Error![]u8 {
    var out = allocator.alloc(u8, text.len - old_len + replacement.len) catch return error.OutOfMemory;
    @memcpy(out[0..at], text[0..at]);
    @memcpy(out[at..][0..replacement.len], replacement);
    @memcpy(out[at + replacement.len ..], text[at + old_len ..]);
    return out;
}

test "reads Cargo and pyproject versions" {
    const cargo = "[package]\nname = \"zap\"\nversion = \"0.7.3\"\nedition = \"2021\"\n";
    try std.testing.expectEqualStrings("0.7.3", try readFrom(.cargo, cargo));

    const pyproject = "[project]\nname = \"zap\"\nversion = \"1.4.0\"\n\n[tool.poetry]\nversion = \"9.9.9\"\n";
    try std.testing.expectEqualStrings("1.4.0", try readFrom(.pyproject, pyproject));

    const poetry = "[tool.poetry]\nname = \"z\"\nversion = \"2.0.1\"\n";
    try std.testing.expectEqualStrings("2.0.1", try readFrom(.pyproject, poetry));
}

test "reads npm and VERSION" {
    const pkg = "{\n  \"name\": \"zap\",\n  \"version\": \"3.2.1\",\n  \"dependencies\": {\"version\": \"nope\"}\n}";
    try std.testing.expectEqualStrings("3.2.1", try readFrom(.npm, pkg));
    try std.testing.expectEqualStrings("0.1.0", try readFrom(.file, "0.1.0\n"));
    try std.testing.expectEqualStrings("0.1.0", try readFrom(.file, "  \"0.1.0\"  \n"));
}

test "missing versions are NotFound, not empty strings" {
    try std.testing.expectError(error.NotFound, readFrom(.cargo, "[package]\nname = \"x\"\n"));
    try std.testing.expectError(error.NotFound, readFrom(.npm, "{}"));
}

test "writes only the version" {
    const a = std.testing.allocator;
    const cargo = "[package]\nname = \"zap\"\nversion = \"0.7.3\"\nedition = \"2021\"\n\n[dependencies]\nversion = \"1\"\n";
    const out = try writeInto(a, .cargo, cargo, "0.8.0");
    defer a.free(out);
    try std.testing.expectEqualStrings("[package]\nname = \"zap\"\nversion = \"0.8.0\"\nedition = \"2021\"\n\n[dependencies]\nversion = \"1\"\n", out);

    const pkg = "{\n  \"version\": \"3.2.1\"\n}\n";
    const pout = try writeInto(a, .npm, pkg, "3.3.0");
    defer a.free(pout);
    try std.testing.expectEqualStrings("{\n  \"version\": \"3.3.0\"\n}\n", pout);
}
