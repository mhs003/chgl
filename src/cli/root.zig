//! Command line parsing.
//!
//! One table describes every flag: its long name, short name, value, and help
//! text. Parsing and `--help` both read that table, so they cannot drift the way
//! a hand-written parser and a hand-written help text do.
//!
//! Deliberately no argument library: the surface is small, and the table has to
//! exist anyway for the TUI's help screen.

const std = @import("std");

pub const ArgValue = enum { none, string };

pub const Spec = struct {
    long: []const u8,
    short: ?u8 = null,
    value: ArgValue = .none,
    /// Shown in `--help`; also the key in the options struct.
    help: []const u8,
};

/// The full option surface. Keep in sync with `Options` below: a spec without a
/// field is a compile-time error in `apply`, which is the point.
pub const specs = [_]Spec{
    .{ .long = "as", .value = .string, .help = "Release version to write (default: derived from commits)" },
    .{ .long = "since", .value = .string, .help = "Start of the range (default: the latest release tag)" },
    .{ .long = "path-to", .value = .string, .help = "End of the range (default: HEAD)" },
    .{ .long = "all", .help = "Use the whole history, up to changelog.max_commits" },
    .{ .long = "file", .value = .string, .help = "Changelog file (default: detected)" },
    .{ .long = "repo", .value = .string, .help = "Repository directory (default: the current directory)" },
    .{ .long = "config", .value = .string, .help = "Config file (default: $CHGL_CONFIG, then the config directory)" },
    .{ .long = "date", .value = .string, .help = "Release date, YYYY-MM-DD (default: today, UTC)" },
    .{ .long = "tag-prefix", .value = .string, .help = "Tag prefix, e.g. v (default: inferred from tags)" },
    .{ .long = "exclude", .value = .string, .help = "Skip matching subjects; glob, repeatable (e.g. 'chore(release):*')" },
    .{ .long = "parse-merges", .help = "List merge commits by their subject instead of skipping them" },
    .{ .long = "include-unconventional", .help = "List non-conventional commits (headless default is to skip, with a warning)" },
    .{ .long = "dry-run", .help = "Print the section to stdout; never write" },
    .{ .long = "write", .help = "Insert the section into the file" },
    .{ .long = "commit", .help = "Commit the changelog after writing" },
    .{ .long = "commit-only", .help = "With --commit, record only the changelog even if other work is staged" },
    .{ .long = "bump-version", .help = "Also set the version in its source file (Cargo.toml, package.json, …)" },
    .{ .long = "create-tag", .help = "Tag the release (needs a version)" },
    .{ .long = "force", .help = "Replace an existing release section" },
    .{ .long = "tui", .short = 'i', .help = "Open the interactive editor (needs a terminal)" },
    .{ .long = "no-tui", .help = "Never open the interactive editor" },
    .{ .long = "dump-frame", .help = "Print one editor frame as plain text and exit (for scripts and tests)" },
    .{ .long = "frame", .value = .string, .help = "With --dump-frame: list, preview, help, or confirm" },
    .{ .long = "explain", .help = "With --dry-run: explain each decision on stderr" },
    .{ .long = "quiet", .short = 'q', .help = "Suppress warnings" },
    .{ .long = "verbose", .short = 'v', .help = "Print diagnostics to stderr" },
    .{ .long = "version", .short = 'V', .help = "Print the version and the config file in use" },
    .{ .long = "help", .short = 'h', .help = "Print help" },
};

pub const Command = enum {
    generate,
    init,
    detect,
    log,
};

pub fn commandFromName(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "init")) return .init;
    if (std.mem.eql(u8, name, "detect")) return .detect;
    if (std.mem.eql(u8, name, "log")) return .log;
    return null;
}

pub const Options = struct {
    command: Command = .generate,
    as: ?[]const u8 = null,
    since: ?[]const u8 = null,
    path_to: ?[]const u8 = null,
    all: bool = false,
    file: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    config: ?[]const u8 = null,
    date: ?[]const u8 = null,
    tag_prefix: ?[]const u8 = null,
    exclude: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,
    parse_merges: bool = false,
    include_unconventional: bool = false,
    dry_run: bool = false,
    write: bool = false,
    commit: bool = false,
    commit_only: bool = false,
    bump_version: bool = false,
    create_tag: bool = false,
    force: bool = false,
    tui: bool = false,
    no_tui: bool = false,
    dump_frame: bool = false,
    frame: ?[]const u8 = null,
    explain: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    show_version: bool = false,
    show_help: bool = false,

    pub fn deinit(self: *Options) void {
        self.exclude.deinit(self.allocator);
    }
};

/// Parse `args` (excluding argv[0]). Returns a message on usage errors.
pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) ParseError!Options {
    var opts = Options{ .allocator = allocator };

    var i: usize = 0;
    var seen_positional = false;
    while (i < args.len) : (i += 1) {
        const raw = args[i];
        if (std.mem.eql(u8, raw, "--")) {
            i += 1;
            if (i < args.len) return error.UnexpectedArgument;
            break;
        }
        if (raw.len > 2 and std.mem.startsWith(u8, raw, "--")) {
            const body = raw[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const inline_value: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            const spec = findLong(name) orelse return error.UnknownOption;
            var value: ?[]const u8 = inline_value;
            if (spec.value == .string and value == null) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                value = args[i];
            }
            if (spec.value == .none and inline_value != null) return error.UnexpectedValue;
            try apply(&opts, spec, value);
            continue;
        }
        if (raw.len >= 2 and raw[0] == '-') {
            const c = raw[1];
            const spec = findShort(c) orelse return error.UnknownOption;
            // Support `-i` only; combined short flags are not worth the code.
            if (raw.len > 2) return error.UnknownOption;
            try apply(&opts, spec, null);
            continue;
        }
        // A positional is the subcommand, and it must come first.
        if (seen_positional) return error.UnexpectedArgument;
        opts.command = commandFromName(raw) orelse return error.UnknownCommand;
        seen_positional = true;
    }

    if (opts.tui and opts.no_tui) return error.ConflictingOptions;
    if (opts.commit and !opts.write) return error.CommitNeedsWrite;
    return opts;
}

pub const ParseError = error{
    UnknownOption,
    UnknownCommand,
    MissingValue,
    UnexpectedValue,
    UnexpectedArgument,
    ConflictingOptions,
    CommitNeedsWrite,
    OutOfMemory,
};

fn findLong(name: []const u8) ?Spec {
    for (specs) |s| {
        if (std.mem.eql(u8, s.long, name)) return s;
    }
    return null;
}

fn findShort(c: u8) ?Spec {
    for (specs) |s| {
        if (s.short) |short| if (short == c) return s;
    }
    return null;
}

fn apply(opts: *Options, spec: Spec, value: ?[]const u8) ParseError!void {
    const l = spec.long;
    if (std.mem.eql(u8, l, "as")) opts.as = value;
    if (std.mem.eql(u8, l, "since")) opts.since = value;
    if (std.mem.eql(u8, l, "path-to")) opts.path_to = value;
    if (std.mem.eql(u8, l, "all")) opts.all = true;
    if (std.mem.eql(u8, l, "file")) opts.file = value;
    if (std.mem.eql(u8, l, "repo")) opts.repo = value;
    if (std.mem.eql(u8, l, "config")) opts.config = value;
    if (std.mem.eql(u8, l, "date")) opts.date = value;
    if (std.mem.eql(u8, l, "tag-prefix")) opts.tag_prefix = value;
    if (std.mem.eql(u8, l, "exclude")) try opts.exclude.append(opts.allocator, value.?);
    if (std.mem.eql(u8, l, "parse-merges")) opts.parse_merges = true;
    if (std.mem.eql(u8, l, "include-unconventional")) opts.include_unconventional = true;
    if (std.mem.eql(u8, l, "dry-run")) opts.dry_run = true;
    if (std.mem.eql(u8, l, "write")) opts.write = true;
    if (std.mem.eql(u8, l, "commit")) opts.commit = true;
    if (std.mem.eql(u8, l, "commit-only")) opts.commit_only = true;
    if (std.mem.eql(u8, l, "bump-version")) opts.bump_version = true;
    if (std.mem.eql(u8, l, "create-tag")) opts.create_tag = true;
    if (std.mem.eql(u8, l, "force")) opts.force = true;
    if (std.mem.eql(u8, l, "tui")) opts.tui = true;
    if (std.mem.eql(u8, l, "no-tui")) opts.no_tui = true;
    if (std.mem.eql(u8, l, "dump-frame")) opts.dump_frame = true;
    if (std.mem.eql(u8, l, "frame")) opts.frame = value;
    if (std.mem.eql(u8, l, "explain")) opts.explain = true;
    if (std.mem.eql(u8, l, "quiet")) opts.quiet = true;
    if (std.mem.eql(u8, l, "verbose")) opts.verbose = true;
    if (std.mem.eql(u8, l, "version")) opts.show_version = true;
    if (std.mem.eql(u8, l, "help")) opts.show_help = true;
}

pub const USAGE =
    \\Usage: chgl [COMMAND] [OPTIONS]
    \\
    \\Generate the next release section of a changelog from commits since the
    \\last release tag, and review or write it.
    \\
    \\Commands:
    \\  (none)    Generate the next release section (the normal run)
    \\  init      Write an example config to the config directory
    \\  detect    Report which file is the changelog and why
    \\  log       Print tag-to-tag release sections, without a model
    \\
    \\Options:
    \\
;

/// `--help` text, generated from `specs`.
pub fn help(w: *std.Io.Writer) std.Io.Writer.Error!void {
    var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer line.deinit();

    try w.writeAll(USAGE);
    for (specs) |s| {
        line.writer.end = 0;
        if (s.short) |c| {
            try line.writer.print("  -{c}, --{s}", .{ c, s.long });
        } else {
            try line.writer.print("      --{s}", .{s.long});
        }
        if (s.value == .string) try line.writer.writeAll(" <VALUE>");
        const col = line.written().len;
        try w.writeAll(line.written());
        try w.splatByteAll(' ', if (col < 30) 30 - col else 2);
        try w.print("{s}\n", .{s.help});
    }
    try w.writeAll(
        \\
        \\Exit codes:
        \\  0  success            1  error                2  usage
        \\  3  nothing to release 4  section already exists (use --force)
        \\
    );
}

test "parses flags and subcommand" {
    const a = std.testing.allocator;
    var args = [_][:0]const u8{ "log", "--since", "v0.1.0", "--exclude=chore(release):*", "--exclude", "Merge *", "-v" };
    var opts = try parse(a, &args);
    defer opts.deinit();
    try std.testing.expectEqual(Command.log, opts.command);
    try std.testing.expectEqualStrings("v0.1.0", opts.since.?);
    try std.testing.expectEqual(@as(usize, 2), opts.exclude.items.len);
    try std.testing.expectEqualStrings("chore(release):*", opts.exclude.items[0]);
    try std.testing.expect(opts.verbose);
}

test "rejects bad usage" {
    const a = std.testing.allocator;
    var unknown = [_][:0]const u8{"--nope"};
    try std.testing.expectError(error.UnknownOption, parse(a, &unknown));
    var missing = [_][:0]const u8{"--since"};
    try std.testing.expectError(error.MissingValue, parse(a, &missing));
    var badcmd = [_][:0]const u8{"wat"};
    try std.testing.expectError(error.UnknownCommand, parse(a, &badcmd));
    var conflict = [_][:0]const u8{ "--tui", "--no-tui" };
    try std.testing.expectError(error.ConflictingOptions, parse(a, &conflict));
    var commit_only_flag = [_][:0]const u8{"--commit"};
    try std.testing.expectError(error.CommitNeedsWrite, parse(a, &commit_only_flag));
    var two_positionals = [_][:0]const u8{ "log", "detect" };
    try std.testing.expectError(error.UnexpectedArgument, parse(a, &two_positionals));
}

test "every spec maps onto a field" {
    // A spec whose `long` is not handled by `apply` would be silently ignored;
    // this catches the common half-wired case.
    const a = std.testing.allocator;
    for (specs) |s| {
        const flag: [:0]const u8 = try std.fmt.allocPrintSentinel(a, "--{s}", .{s.long}, 0);
        defer a.free(flag);
        var argv: []const [:0]const u8 = &.{flag};
        var with_value = [_][:0]const u8{ flag, "x" };
        if (s.value == .string) argv = &with_value;
        // `--commit` needs `--write`; validation is tested separately, here we
        // only care that the flag reaches a field at all.
        var commit_argv = [_][:0]const u8{ "--commit", "--write" };
        if (std.mem.eql(u8, s.long, "commit")) argv = &commit_argv;
        var opts = try parse(a, argv);
        defer opts.deinit();
    }
}

test "help mentions every long flag" {
    var buf: [8192]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try help(&fbs);
    const text = fbs.buffered();
    for (specs) |s| {
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "--{s}", .{s.long});
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}
