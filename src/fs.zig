//! File access rooted at the repository.
//!
//! Everything the plan reads goes through here so it is relative to the repo
//! root, not the process's working directory, and so tests can swap it.

const std = @import("std");

pub const Fs = struct {
    dir: std.Io.Dir,
    io: std.Io,

    pub fn open(io: std.Io, path: []const u8) !Fs {
        return .{ .dir = try std.Io.Dir.openDirAbsolute(io, path, .{}), .io = io };
    }

    pub fn close(self: Fs) void {
        self.dir.close(self.io);
    }

    /// True for a file *or* a directory: detection probes fragment directories
    /// (`.changeset`) as well as files.
    pub fn exists(self: Fs, path: []const u8) bool {
        const stat = self.dir.statFile(self.io, path, .{}) catch return false;
        return stat.kind == .file or stat.kind == .directory;
    }

    pub fn readAlloc(self: Fs, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        return self.dir.readFileAlloc(self.io, path, allocator, .limited(8 << 20)) catch null;
    }

    /// Write atomically: a sibling temp file, then rename over the target, so a
    /// failure never leaves a half-written changelog.
    pub fn writeAtomic(self: Fs, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        const tmp = try std.fmt.allocPrint(allocator, "{s}.chgl-tmp", .{path});
        defer allocator.free(tmp);

        var file = try self.dir.createFile(self.io, tmp, .{ .truncate = true });
        var wrote = false;
        defer if (!wrote) {
            const gone = self.dir.deleteFile(self.io, tmp) catch {};
            _ = gone;
        };
        {
            var wbuf: [8192]u8 = undefined;
            var writer: std.Io.File.Writer = .init(file, self.io, &wbuf);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
        }
        file.close(self.io);
        try self.dir.rename(tmp, self.dir, path, self.io);
        wrote = true;
    }

    /// Context callbacks for `plan.Request`.
    pub fn readCallback(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        return self.readAlloc(allocator, path);
    }

    pub fn existsCallback(ctx: *anyopaque, path: []const u8) bool {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        return self.exists(path);
    }
};
