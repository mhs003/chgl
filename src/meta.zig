//! Repository meta-tests: things a release depends on but that no single
//! module owns.

const std = @import("std");

test "VERSION is a plain semver" {
    const raw = @embedFile("VERSION");
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const semver = @import("version/semver.zig");
    try std.testing.expect(semver.Semver.parse(trimmed) != null);
    // The whole file is one version and a newline; a stray second line would
    // end up in the tag.
    try std.testing.expect(trimmed.len + 1 == raw.len or trimmed.len == raw.len);
}

test "the binary reports the version in VERSION" {
    const main = @import("main.zig");
    const raw = @embedFile("VERSION");
    try std.testing.expectEqualStrings(std.mem.trim(u8, raw, " \t\r\n"), main.VERSION);
}
