//! Shared error reporting.
//!
//! Zig's error sets carry no message, so a failure that the user must act on
//! travels with one. `Report` is what `main` prints to stderr; the exit code
//! comes from the same struct so call sites cannot disagree with the message.

const std = @import("std");

pub const ExitCode = u8;

pub const Report = struct {
    code: ExitCode,
    msg: []const u8,

    pub fn init(code: ExitCode, msg: []const u8) Report {
        return .{ .code = code, .msg = msg };
    }
};

/// The pipeline's error set. Every value here has a `Report` produced at the
/// point of failure, because only that code knows what to tell the user.
pub const Error = error{
    Usage,
    NoRepo,
    NoChangelog,
    NotMarkdown,
    Unparsable,
    NoVersion,
    NothingToRelease,
    SectionExists,
    DirtyIndex,
    GitFailed,
    ConfigInvalid,
    OutOfMemory,
    Io,
    Cancelled,
};

pub fn exitCode(err: anyerror) ExitCode {
    return switch (err) {
        error.NothingToRelease => 3,
        error.SectionExists => 4,
        error.Usage => 2,
        error.Cancelled => 1,
        else => 1,
    };
}

/// Accumulates what the run needs to tell the user. Warnings do not fail the
/// run; they are printed to stderr before the result.
pub const Notices = struct {
    list: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Notices {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Notices) void {
        self.list.deinit(self.allocator);
    }

    pub fn add(self: *Notices, msg: []const u8) !void {
        try self.list.append(self.allocator, msg);
    }

    pub fn count(self: Notices) usize {
        return self.list.items.len;
    }
};

test "exit codes match the documented contract" {
    try std.testing.expectEqual(@as(ExitCode, 3), exitCode(error.NothingToRelease));
    try std.testing.expectEqual(@as(ExitCode, 4), exitCode(error.SectionExists));
    try std.testing.expectEqual(@as(ExitCode, 2), exitCode(error.Usage));
    try std.testing.expectEqual(@as(ExitCode, 1), exitCode(error.NoRepo));
}
