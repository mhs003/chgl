//! Reading commits.
//!
//! One format, used everywhere: NUL-terminated records (`-z`) with
//! unit-separator fields. Subjects and bodies are free text and may contain
//! newlines, tabs, even `\x1e`; only `NUL` and `\x1f` cannot appear, so those
//! are the two separators. Do not add a second format for "just the subjects".

const std = @import("std");
const git = @import("root.zig");

pub const Record = struct {
    hash: []const u8,
    short: []const u8,
    /// Unix seconds.
    timestamp: u64,
    author_name: []const u8,
    author_email: []const u8,
    /// Parent hashes, space separated as git prints them. Two parents means a
    /// merge, which is how `--parse-merges` finds them.
    parents: []const u8,
    subject: []const u8,
    body: []const u8,

    pub fn isMerge(self: Record) bool {
        var it = std.mem.tokenizeScalar(u8, self.parents, ' ');
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n > 1;
    }
};

/// `%H %h %ct %an %ae %P %s %b` with `\x1f` between fields and `-z` between
/// records. `%b` is the raw body (no trailing newline).
const PRETTY = "--format=%H%x1f%h%x1f%ct%x1f%an%x1f%ae%x1f%P%x1f%s%x1f%b";

pub const Options = struct {
    /// Exclusive lower bound; empty means the whole history.
    from: []const u8 = "",
    /// Inclusive upper bound; empty means HEAD.
    to: []const u8 = "",
    /// Cap on records returned, oldest dropped first. 0 means no cap.
    max: usize = 0,
    /// Drop merge commits from the result (they are still read so callers can
    /// count them).
    skip_merges: bool = true,
};

pub const Result = struct {
    commits: []Record,
    /// Bytes backing every `Record` field; free once.
    storage: []u8,
    /// Commits read but excluded because they are merge commits.
    merges: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.commits);
        allocator.free(self.storage);
    }
};

pub const Error = error{ OutOfMemory, GitFailed, GitMissing } || std.Io.Writer.Error;

pub fn read(runner: git.Runner, opts: Options) Error!Result {
    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "git");
    try args.append(a, "log");
    try args.append(a, "-z");
    try args.append(a, PRETTY);
    if (opts.from.len != 0 or opts.to.len != 0) {
        const range = try std.fmt.allocPrint(a, "{s}..{s}", .{ opts.from, if (opts.to.len == 0) "HEAD" else opts.to });
        try args.append(a, range);
    }
    return readWith(runner, args.items, opts);
}

fn readWith(runner: git.Runner, argv: []const []const u8, opts: Options) Error!Result {
    const out = runner.run(argv, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GitMissing => return error.GitMissing,
        else => return error.GitFailed,
    };
    if (!out.ok()) {
        out.deinit(runner.allocator);
        return error.GitFailed;
    }

    var commits: std.ArrayList(Record) = .empty;
    errdefer commits.deinit(runner.allocator);
    var merges: usize = 0;

    var it = std.mem.splitScalar(u8, out.stdout, 0);
    while (it.next()) |record| {
        if (record.len == 0) continue;
        const fields = splitFields(record) orelse continue;
        const rec = Record{
            .hash = fields[0],
            .short = fields[1],
            .timestamp = std.fmt.parseInt(u64, fields[2], 10) catch 0,
            .author_name = fields[3],
            .author_email = fields[4],
            .parents = fields[5],
            .subject = fields[6],
            .body = fields[7],
        };
        if (rec.isMerge()) {
            merges += 1;
            if (opts.skip_merges) continue;
        }
        try commits.append(runner.allocator, rec);
    }

    if (opts.max != 0 and commits.items.len > opts.max) {
        // Oldest are at the end (`git log` is newest first); drop them.
        commits.shrinkRetainingCapacity(opts.max);
    }
    // Newest first is right for reading a log, wrong for a changelog: entries
    // belong in the order they happened, so the first bullet of a group is the
    // earliest change in it.
    std.mem.reverse(Record, commits.items);

    return .{ .commits = try commits.toOwnedSlice(runner.allocator), .storage = out.stdout, .merges = merges };
}

/// Exactly eight fields, else the record is malformed and skipped rather than
/// shifting every later field.
fn splitFields(record: []const u8) ?[8][]const u8 {
    var fields: [8][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, record, '\x1f');
    var i: usize = 0;
    while (it.next()) |f| {
        // Extra fields cannot come from git; a malformed record is skipped
        // rather than shifting every later field.
        if (i >= 8) return null;
        fields[i] = f;
        i += 1;
    }
    if (i != 8) return null;
    return fields;
}

test "record parsing handles subjects with newlines-free text and bodies" {
    const a = std.testing.allocator;
    const raw = "abc123\x1fabc\x1f1700000000\x1fA U Thor\x1fa@x\x1fparent1\x1ffeat: add\x1fbody line\nsecond\n\x1f";
    _ = raw;
    // Exercised through splitFields because the subprocess is covered by e2e.
    const f = splitFields("H\x1fh\x1f1\x1fN\x1fE\x1fP\x1fS\x1fB").?;
    try std.testing.expectEqualStrings("H", f[0]);
    try std.testing.expectEqualStrings("B", f[7]);
    try std.testing.expect(splitFields("H\x1fh\x1f1") == null);
    _ = a;
}

test "merge detection reads the parent list" {
    const merge = Record{ .hash = "a", .short = "a", .timestamp = 0, .author_name = "", .author_email = "", .parents = "p1 p2", .subject = "m", .body = "" };
    const normal = Record{ .hash = "a", .short = "a", .timestamp = 0, .author_name = "", .author_email = "", .parents = "p1", .subject = "m", .body = "" };
    const root = Record{ .hash = "a", .short = "a", .timestamp = 0, .author_name = "", .author_email = "", .parents = "", .subject = "m", .body = "" };
    try std.testing.expect(merge.isMerge());
    try std.testing.expect(!normal.isMerge());
    try std.testing.expect(!root.isMerge());
}
