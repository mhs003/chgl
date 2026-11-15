//! chgl — generate and review the next release section of a changelog.
//!
//! stdout carries only the rendered section, so it pipes to a file or into a
//! release body. Everything else — notices, warnings, errors, and the whole
//! interactive editor — goes to stderr or the terminal.

const std = @import("std");

const cli = @import("cli/root.zig");
const config = @import("config/root.zig");
const detect = @import("detect.zig");
const errors = @import("errors.zig");
const fs = @import("fs.zig");
const git = @import("git/root.zig");
const plan_mod = @import("plan.zig");
const render = @import("render.zig");
const source = @import("version/source.zig");
const tui = @import("tui/root.zig");
const worktree = @import("git/worktree.zig");

/// Embedded at compile time from the repository's `VERSION` file, so the
/// binary reports what was built and there is one source of truth.
pub const VERSION = std.mem.trim(u8, @embedFile("VERSION"), " \t\r\n");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const out = &stdout_file.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const err = &stderr_file.interface;

    const code = run(init, args, out, err) catch |e| {
        err.print("chgl: unexpected failure: {s}\n", .{@errorName(e)}) catch {};
        return;
    };
    out.flush() catch {};
    err.flush() catch {};
    std.process.exit(code);
}

fn run(init: std.process.Init, args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const gpa = init.gpa;

    var opts = cli.parse(gpa, if (args.len > 1) args[1..] else &.{}) catch |e| {
        switch (e) {
            error.OutOfMemory => return 1,
            else => {
                try err.print("chgl: {s}\n\n", .{usageMessage(e)});
                try cli.help(err);
                return 2;
            },
        }
    };
    defer opts.deinit();

    if (opts.show_help) {
        try cli.help(out);
        return 0;
    }
    if (opts.show_version) {
        try out.print("chgl {s}\n", .{VERSION});
        // The config path is the other thing people cannot find.
        if (opts.config) |p| {
            try out.print("config: {s}\n", .{p});
        } else if (configPath(gpa, opts, init) catch null) |p| {
            defer gpa.free(p);
            try out.print("config: {s}\n", .{p});
        } else {
            try out.writeAll("config: none (defaults apply; `chgl init` writes one)\n");
        }
        return 0;
    }

    switch (opts.command) {
        .init => return cmdInit(gpa, init, opts, err),
        .detect => return cmdDetect(gpa, init, opts, out, err),
        .log, .generate => return cmdGenerate(gpa, init, opts, out, err),
    }
}

fn usageMessage(e: cli.ParseError) []const u8 {
    return switch (e) {
        error.UnknownOption => "unknown option",
        error.UnknownCommand => "unknown command",
        error.MissingValue => "missing value for an option",
        error.UnexpectedValue => "this option does not take a value",
        error.UnexpectedArgument => "unexpected argument",
        error.ConflictingOptions => "--tui and --no-tui conflict",
        error.CommitNeedsWrite => "--commit needs --write",
        error.OutOfMemory => "out of memory",
    };
}

fn cmdInit(gpa: std.mem.Allocator, init: std.process.Init, opts: cli.Options, err: *std.Io.Writer) !u8 {
    var env = config.EnvGetter{ .map = init.environ_map };
    const dir = config.configDirFrom(config.PLATFORM, env.getter()) orelse {
        try err.writeAll("chgl: cannot determine the config directory; set HOME or XDG_CONFIG_HOME\n");
        return 1;
    };
    const path = try std.fmt.allocPrint(gpa, "{s}/config.toml", .{dir});
    defer gpa.free(path);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(init.io, dir) catch {
        try err.print("chgl: cannot create {s}\n", .{dir});
        return 1;
    };
    if (!opts.force) {
        if (cwd.openFile(init.io, path, .{ .mode = .read_only })) |f| {
            f.close(init.io);
            try err.print("chgl: {s} already exists; pass --force to overwrite\n", .{path});
            return 1;
        } else |_| {}
    }
    var file = cwd.createFile(init.io, path, .{ .truncate = true }) catch {
        try err.print("chgl: cannot write {s}\n", .{path});
        return 1;
    };
    defer file.close(init.io);
    var buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .init(file, init.io, &buf);
    try w.interface.writeAll(config.EXAMPLE_TOML);
    try w.interface.flush();
    try err.print("chgl: wrote {s}\n", .{path});
    return 0;
}

fn cmdDetect(gpa: std.mem.Allocator, init: std.process.Init, opts: cli.Options, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const runner = if (opts.repo) |r| git.Runner.init(init.io, gpa).inDir(r) else git.Runner.init(init.io, gpa);
    const repo = findRepo(init, opts) catch {
        try err.writeAll("chgl: not inside a git repository\n");
        return 1;
    };
    defer gpa.free(repo);

    var opened = fs.Fs.open(init.io, repo) catch {
        try err.print("chgl: cannot open {s}\n", .{repo});
        return 1;
    };
    defer opened.close();

    const forced: ?[]const u8 = if (opts.file) |f| f else null;
    const result = detect.detect(gpa, .{
        .ctx = &opened,
        .exists = fs.Fs.existsCallback,
        .read = fs.Fs.readCallback,
    }, forced) catch |e| return e;
    defer {
        for (result.ranked) |c| gpa.free(c.path);
        result.deinit(gpa);
    }

    try out.print("repository: {s}\n", .{repo});
    if (result.chosen) |c| {
        try out.print("changelog: {s}  ({s}, {s})\n", .{ c.path, c.reason, c.format.name() });
        if (!c.format.writable()) {
            try out.print("note: {s} is not writable by chgl (Markdown only)\n", .{c.format.name()});
        }
    } else {
        try out.writeAll("changelog: none found\n");
    }
    if (result.fragment_dir) |d| {
        try out.print("fragments: {s} (chgl does not read fragment changelogs yet)\n", .{d});
    }
    if (result.ranked.len > 1) {
        try out.writeAll("candidates:\n");
        for (result.ranked) |c| {
            try out.print("  {d:>4}  {s}  ({s})\n", .{ c.score, c.path, c.reason });
        }
    }
    _ = runner;
    return 0;
}

fn cmdGenerate(gpa: std.mem.Allocator, init: std.process.Init, opts: cli.Options, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    // Config is optional: without a file the defaults apply, and the tool stays
    // useful on a fresh checkout.
    var parsed_cfg: ?config.Parsed = null;
    defer if (parsed_cfg) |*p| p.deinit();
    const cfg = blk: {
        if (configPath(gpa, opts, init) catch null) |path| {
            defer gpa.free(path);
            const cwd = std.Io.Dir.cwd();
            const text = cwd.readFileAlloc(init.io, path, gpa, .limited(1 << 20)) catch {
                try err.print("chgl: cannot read {s}\n", .{path});
                return 1;
            };
            defer gpa.free(text);
            const parsed = config.parseText(gpa, path, text) catch |e| {
                try err.print("chgl: {s}: {s}\n", .{ path, configErrorMessage(e) });
                return 1;
            };
            parsed_cfg = parsed;
            break :blk parsed.config;
        }
        break :blk config.Config{};
    };

    // `--exclude` adds to whatever the config lists; both are globs.
    var cfg_with_cli = cfg;
    if (opts.exclude.items.len != 0) {
        const merged = try gpa.alloc([]const u8, cfg.changelog.exclude.len + opts.exclude.items.len);
        defer gpa.free(merged);
        @memcpy(merged[0..cfg.changelog.exclude.len], cfg.changelog.exclude);
        @memcpy(merged[cfg.changelog.exclude.len..], opts.exclude.items);
        cfg_with_cli.changelog.exclude = merged;
        return generateWith(gpa, init, opts, cfg_with_cli, out, err);
    }
    return generateWith(gpa, init, opts, cfg_with_cli, out, err);
}

fn generateWith(gpa: std.mem.Allocator, init: std.process.Init, opts_in: cli.Options, cfg: config.Config, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var opts = opts_in;
    const runner = if (opts.repo) |r| git.Runner.init(init.io, gpa).inDir(r) else git.Runner.init(init.io, gpa);

    const repo = findRepo(init, opts) catch {
        try err.writeAll("chgl: not inside a git repository\n");
        return 1;
    };
    defer gpa.free(repo);

    var opened = fs.Fs.open(init.io, repo) catch {
        try err.print("chgl: cannot open {s}\n", .{repo});
        return 1;
    };
    defer opened.close();

    const today = try todayUtc(gpa, init);
    defer gpa.free(today);

    var plan = plan_mod.build(gpa, .{
        .cfg = cfg,
        .runner = runner,
        .forced_file = opts.file,
        .since = opts.since,
        .version_override = opts.as,
        .all = opts.all,
        .date_override = opts.date,
        .tag_prefix = opts.tag_prefix,
        .parse_merges = opts.parse_merges,
        .include_unconventional = opts.include_unconventional,
        .force = opts.force,
        .interactive = false,
        .today = today,
        .read_file = fs.Fs.readCallback,
        .exists_file = fs.Fs.existsCallback,
        .ctx = &opened,
    }) catch |e| {
        try reportPlanError(e, err, opts);
        return errors.exitCode(e);
    };
    defer plan.deinit();

    if (!opts.quiet) {
        for (plan.notices.items) |n| try err.print("chgl: {s}\n", .{n});
    }

    if (opts.explain) {
        // "Why is that commit missing?" is the first question after a wrong
        // guess, so the reasons are printable without opening the editor.
        for (plan.release.entries.items) |e| {
            const shown = if (e.from_file) "file" else "commits";
            try err.print("chgl: {s:<4} [{s}] {s}\n", .{ e.state.label(), shown, e.subject });
            if (e.reason != .none) try err.print("chgl:      {s}\n", .{e.reason.label()});
        }
        try err.print("chgl: range {s}: {d} commits, {d} kept\n", .{ plan.range.description, plan.total_commits, plan.release.count(.keep) });
    }

    if (opts.command == .log) {
        // `log` prints tag-to-tag sections for the current range, and never
        // writes: it is the no-decisions view used to check a mapping.
        const section = try plan.section(.{});
        defer gpa.free(section);
        try out.writeAll(section);
        try out.writeAll("\n");
        return 0;
    }

    // Decided before anything is written: a release with no content is not a
    // release, and writing an empty section for it would be noise in the file.
    if (!plan.releasable()) {
        try err.print("chgl: nothing to release in {s} ({d} commits, none releasable)\n", .{ plan.range.description, plan.total_commits });
        if (opts.write or opts.commit or opts.create_tag) return 3;
    }

    const links = render.LinkStyle{ .repo_url = remoteUrlRepo(gpa, runner), .commit_links = cfg.output.commit_links, .issue_links = cfg.output.issue_links };
    defer if (links.repo_url) |u| gpa.free(u);

    // The editor is a view over the plan: it can change which entries ship,
    // never what the entries are.
    var plan_view = tui.PlanView{ .plan = &plan, .links = links };
    var state = tui.State.init(plan_view.view(), gpa);
    state.outcome = tui.defaultOutcome(opts.write, opts.commit, opts.create_tag);

    if (opts.dump_frame) {
        // Lets the layout be inspected (and tested) without a terminal.
        if (opts.frame) |f| {
            if (std.mem.eql(u8, f, "preview")) state.mode = .preview;
            if (std.mem.eql(u8, f, "help")) state.mode = .help;
            if (std.mem.eql(u8, f, "confirm")) state.mode = .confirm;
        }
        try tui.dumpFrame(&state, gpa, 90, 24, out);
        return 0;
    }

    if (opts.tui and !opts.no_tui) {
        var terminal = tui.Terminal.open(init.io) catch {
            try err.writeAll("chgl: --tui needs a terminal (no /dev/tty); showing the preview instead\n");
            const section = try plan.section(links);
            defer gpa.free(section);
            try out.writeAll(section);
            try out.writeAll("\n");
            return 0;
        };
        defer terminal.close();
        const chosen = tui.run(&terminal, &state, gpa, err) catch |e| {
            try err.print("chgl: editor failed: {s}\n", .{@errorName(e)});
            return 1;
        };
        if (chosen == .cancelled) {
            try err.writeAll("chgl: cancelled; nothing was written\n");
            return 1;
        }
        // The editor decided the action; apply exactly that.
        opts.write = true;
        opts.commit = chosen == .write_commit or chosen == .write_commit_tag;
        opts.create_tag = chosen == .write_commit_tag;
    }

    if (!opts.write) {
        const section = try plan.section(links);

        defer gpa.free(section);
        try out.writeAll(section);
        try out.writeAll("\n");
        return 0;
    }

    // --- write ---------------------------------------------------------
    const result = try plan.resultingFile(links);
    defer gpa.free(result);
    opened.writeAtomic(gpa, plan.file_path, result) catch {
        try err.print("chgl: cannot write {s}\n", .{plan.file_path});
        return 1;
    };
    try err.print("chgl: wrote {s}\n", .{plan.file_path});

    // Version write-back is opt-in: many projects bump in a separate commit and
    // rewriting their manifest here would show up as an unexpected diff.
    if (opts.bump_version) {
        if (plan.version_source) |vs| {
            if (plan.version) |v| {
                var vbuf: [64]u8 = undefined;
                const new_version = try v.render(&vbuf);
                if (!std.mem.eql(u8, new_version, vs.version)) {
                    const text = opened.readAlloc(gpa, vs.path) orelse {
                        try err.print("chgl: cannot read {s}\n", .{vs.path});
                        return 1;
                    };
                    defer gpa.free(text);
                    const updated = source.writeInto(gpa, vs.kind, text, new_version) catch {
                        try err.print("chgl: cannot update the version in {s}\n", .{vs.path});
                        return 1;
                    };
                    opened.writeAtomic(gpa, vs.path, updated) catch {
                        try err.print("chgl: cannot write {s}\n", .{vs.path});
                        gpa.free(updated);
                        return 1;
                    };
                    gpa.free(updated);
                    try err.print("chgl: set {s} to {s}\n", .{ vs.path, new_version });
                } else {
                    try err.print("chgl: {s} is already {s}\n", .{ vs.path, new_version });
                }
            }
        } else {
            try err.writeAll("chgl: --bump-version needs a version source (Cargo.toml, package.json, pyproject.toml, VERSION)\n");
        }
    }
    if (opts.commit) {
        var path_list: [2][]const u8 = undefined;
        var n_paths: usize = 1;
        path_list[0] = plan.file_path;
        if (opts.bump_version) {
            if (plan.version_source) |vs| {
                path_list[1] = vs.path;
                n_paths = 2;
            }
        }
        const paths = path_list[0..n_paths];
        worktree.stage(runner, paths) catch {
            try err.writeAll("chgl: could not stage the changelog\n");
            return 1;
        };
        var msg_buf: [256]u8 = undefined;
        const msg = if (plan.version) |v| blk: {
            var vbuf: [64]u8 = undefined;
            break :blk try std.fmt.bufPrint(&msg_buf, "chore(release): {s}{s}", .{ plan.version_style.prefix, try v.render(&vbuf) });
        } else "chore: update changelog";
        worktree.commit(runner, msg, if (opts.commit_only) paths else null) catch {
            try err.writeAll("chgl: commit failed\n");
            return 1;
        };
        try err.print("chgl: committed {s}\n", .{msg});
    }

    if (opts.create_tag) {
        const v = plan.version orelse {
            try err.writeAll("chgl: --create-tag needs a version (pass --as)\n");
            return 1;
        };
        var tag_buf: [128]u8 = undefined;
        var vbuf: [64]u8 = undefined;
        const tag_name = try @import("version/semver.zig").formatTag(plan.version_style, v, &tag_buf);
        var tag_msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&tag_msg_buf, "Release {s}", .{try v.render(&vbuf)});
        worktree.tag(runner, tag_name, msg) catch |e| {
            if (e == error.TagExists) {
                try err.print("chgl: tag {s} already exists\n", .{tag_name});
            } else {
                try err.writeAll("chgl: could not create the tag\n");
            }
            return 1;
        };
        try err.print("chgl: tagged {s}\n", .{tag_name});
    }

    return 0;
}

fn configErrorMessage(e: anytype) []const u8 {
    return switch (e) {
        error.UnknownKey => "unknown key (check for a typo)",
        error.Invalid => "invalid value",
        else => "could not parse the config",
    };
}

fn remoteUrlRepo(gpa: std.mem.Allocator, runner: git.Runner) ?[]const u8 {
    const raw = git.remoteUrl(runner) orelse return null;
    defer runner.allocator.free(raw);
    return normalizeRemote(gpa, raw) catch null;
}

/// `git@github.com:o/r.git` → `https://github.com/o/r`.
pub fn normalizeRemote(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, s, "git@")) {
        const rest = s["git@".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return gpa.dupe(u8, s);
        const host = rest[0..colon];
        const path = std.mem.trimStart(u8, rest[colon + 1 ..], "/");
        return std.fmt.allocPrint(gpa, "https://{s}/{s}", .{ host, std.mem.trimEnd(u8, path, ".git") });
    }
    if (std.mem.startsWith(u8, s, "ssh://git@")) {
        s = s["ssh://git@".len..];
        return std.fmt.allocPrint(gpa, "https://{s}", .{std.mem.trimEnd(u8, s, "/")});
    }
    if (std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://")) {
        const trimmed = std.mem.trimEnd(u8, s, "/");
        const without_git = if (std.mem.endsWith(u8, trimmed, ".git")) trimmed[0 .. trimmed.len - 4] else trimmed;
        return gpa.dupe(u8, without_git);
    }
    return gpa.dupe(u8, s);
}

fn configPath(gpa: std.mem.Allocator, opts: cli.Options, init: std.process.Init) !?[]u8 {
    if (opts.config) |p| return try gpa.dupe(u8, p);
    if (init.environ_map.get("CHGL_CONFIG")) |p| {
        if (std.mem.trim(u8, p, " \t").len != 0) return try gpa.dupe(u8, p);
    }
    var env = config.EnvGetter{ .map = init.environ_map };
    const dir = config.configDirFrom(config.PLATFORM, env.getter()) orelse return null;
    const cwd = std.Io.Dir.cwd();
    const candidates = [_][]const u8{ "config.toml", "config.json" };
    for (candidates) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
        if (cwd.access(init.io, path, .{})) |_| {
            return path;
        } else |_| {
            gpa.free(path);
        }
    }
    return null;
}

fn findRepo(init: std.process.Init, opts: cli.Options) ![]u8 {
    const gpa = init.gpa;
    if (opts.repo) |r| return try gpa.dupe(u8, r);
    const runner = git.Runner.init(init.io, gpa);
    return worktree.root(runner) catch return error.GitFailed;
}

fn todayUtc(gpa: std.mem.Allocator, init: std.process.Init) ![]u8 {
    const now = std.Io.Clock.real.now(init.io);
    const secs: u64 = @intCast(@max(now.toSeconds(), 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

fn reportPlanError(e: anytype, err: *std.Io.Writer, opts: cli.Options) !void {
    _ = opts;
    switch (e) {
        error.NoChangelog => try err.writeAll("chgl: no changelog found; create one (CHANGELOG.md) or pass --file\n"),
        error.FragmentsOnly => try err.writeAll("chgl: this repository uses changelog fragments; chgl does not read them yet\n"),
        error.SectionExists => try err.writeAll("chgl: that release section already exists (pass --force to write it again)\n"),
        error.NotMarkdown => try err.writeAll("chgl: the detected changelog is not Markdown (see above)\n"),
        error.Unparsable => try err.writeAll("chgl: the changelog has no version headings, so a release section has no place to go\n"),
        error.NoRepo => try err.writeAll("chgl: the repository has no commits\n"),
        error.GitMissing => try err.writeAll("chgl: git is not installed\n"),
        error.GitFailed => try err.writeAll("chgl: a git command failed (see above)\n"),
        else => try err.writeAll("chgl: failed to build the release\n"),
    }
}
