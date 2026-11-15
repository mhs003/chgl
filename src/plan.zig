//! Building the plan: everything the run decided, in one value.
//!
//! `--dry-run`, `--write`, `--commit`, `--create-tag` and the TUI all consume
//! this. Nothing downstream re-derives a decision, so "the TUI shows exactly
//! what it will write" and "CI writes exactly what the preview showed" are the
//! same statement.

const std = @import("std");
const errors = @import("errors.zig");
const config = @import("config/root.zig");
const git = @import("git/root.zig");
const log = @import("git/log.zig");
const tags = @import("git/tags.zig");
const detect = @import("detect.zig");
const changelog = @import("changelog.zig");
const entry_mod = @import("release/entry.zig");
const render = @import("render.zig");
const semver = @import("version/semver.zig");
const source = @import("version/source.zig");

pub const Release = entry_mod.Release;
pub const Entry = entry_mod.Entry;
pub const Group = entry_mod.Group;

pub const Range = struct {
    /// Tag name used as the lower bound, empty for the whole history.
    from_tag: []const u8 = "",
    /// Human description for output, e.g. `v0.7.3..HEAD` or `whole history`.
    description: []const u8 = "",
    whole_history: bool = false,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    /// Changelog path relative to the repo root (as the user would see it).
    file_path: []const u8,
    format: detect.Format,
    /// Original file contents; empty when the file does not exist yet.
    original: []const u8,
    exists: bool,
    doc: changelog.Document,
    placement: changelog.Placement,
    release: Release,
    /// Commits read from the range (before skipping).
    total_commits: usize,
    range: Range,
    current_version: ?semver.Semver,
    version: ?semver.Semver,
    version_style: semver.TagStyle,
    version_source: ?source.Source,
    date: []const u8,
    /// Heading as it will be written, e.g. `## [0.8.0] - 2026-11-15`.
    heading: []const u8,
    /// The file's existing group titles, so new ones match.
    vocabulary: []const []const u8,
    /// Everything the caller should show the user before finishing.
    notices: std.ArrayList([]const u8) = .empty,

    /// Whether the changelog file already exists (it may be created with --init).
    created: bool = false,

    /// Set when this release absorbed `[Unreleased]` content, so the original
    /// entries are removed from that section after insertion.
    absorbed_cleared: bool = true,

    pub fn deinit(self: *Plan) void {
        for (self.notices.items) |n| self.allocator.free(n);
        self.notices.deinit(self.allocator);
        self.doc.deinit(self.allocator);
        self.release.deinit(self.allocator);
        self.allocator.free(self.repo_root);
        self.allocator.free(self.file_path);
        self.allocator.free(self.heading);
        self.allocator.free(self.vocabulary);
        self.allocator.free(self.original);
        if (self.version_source) |vs| {
            self.allocator.free(vs.path);
            self.allocator.free(vs.version);
        }
        if (self.range.description.len != 0) self.allocator.free(self.range.description);
    }

    pub fn note(self: *Plan, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.notices.append(self.allocator, msg);
    }

    /// The rendered section (heading included), for preview and stdout.
    pub fn section(self: *Plan, links: render.LinkStyle) ![]u8 {
        return render.section(self.allocator, .{
            .heading = self.heading,
            .entries = self.release.entries.items,
            .vocabulary = self.vocabulary,
            .links = links,
            .eol = self.doc.eol,
        });
    }

    /// The whole file as it will be written. This is what the TUI previews and
    /// what `--write` writes.
    pub fn resultingFile(self: *Plan, links: render.LinkStyle) ![]u8 {
        const body = try sectionBody(self, links);
        defer self.allocator.free(body);

        // Order matters: every edit below is computed from offsets in `base`,
        // so `base` may only change *before* the next edit is calculated.
        //
        // 1. Empty the [Unreleased] content that this release absorbed, while
        //    the offsets still describe the file on disk.
        var base: []const u8 = self.original;
        var owned_base: ?[]u8 = null;
        errdefer if (owned_base) |b| self.allocator.free(b);
        if (self.placement.unreleased != null and self.absorbed_cleared) {
            const cleared = try changelog.edit.clearUnreleased(self.allocator, self.original, self.doc, changelog.edit.eolOf(self.doc));
            owned_base = cleared;
            base = cleared;
        }
        // 2. Splice the new section in.
        var out = try changelog.edit.insert(self.allocator, base, self.placement, .{
            .heading = self.heading,
            .body = body,
            .eol = changelog.edit.eolOf(self.doc),
        });
        errdefer self.allocator.free(out);

        // 3. Move reference-style footers forward, or the new heading renders
        //    as literal `[0.8.0]` text.
        if (try self.footerUpdate()) |new_trailer| {
            defer self.allocator.free(new_trailer);
            if (self.doc.trailer.len > 0 and out.len >= self.doc.trailer.len and
                std.mem.endsWith(u8, out, self.doc.trailer))
            {
                const head = out[0 .. out.len - self.doc.trailer.len];
                const rebuilt = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ head, new_trailer });
                self.allocator.free(out);
                out = rebuilt;
            }
        }
        return out;
    }

    /// The updated footer block, or null when the file has none.
    pub fn footerUpdate(self: *Plan) !?[]u8 {
        const v = self.version orelse return null;
        var tag_buf: [128]u8 = undefined;
        const tag = try @import("version/semver.zig").formatTag(self.version_style, v, &tag_buf);
        var label_buf: [64]u8 = undefined;
        const label = try v.render(&label_buf);
        return changelog.edit.rewriteFooter(self.allocator, self.doc, .{
            .new_label = label,
            .new_tag = tag,
            .previous_tag = if (self.range.from_tag.len != 0) self.range.from_tag else null,
            .repo_url = null,
        }) catch null;
    }

    pub fn sectionBody(self: *Plan, links: render.LinkStyle) ![]u8 {
        return render.body(self.allocator, .{
            .heading = self.heading,
            .entries = self.release.entries.items,
            .vocabulary = self.vocabulary,
            .links = links,
            .eol = self.doc.eol,
        });
    }

    /// At least one entry justifies a release.
    pub fn releasable(self: Plan) bool {
        return self.release.releasable();
    }

    /// Current version for display, or `-` when there is no source.
    pub fn current_version_label(self: Plan) []const u8 {
        const v = self.current_version orelse return "-";
        var buf: [64]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        fbs.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch return "-";
        return std.heap.page_allocator.dupe(u8, fbs.buffered()) catch "-";
    }
};

pub const Request = struct {
    cfg: config.Config,
    runner: git.Runner,
    /// From `--file`; skips detection.
    forced_file: ?[]const u8 = null,
    /// From `--since`; skips tag selection.
    since: ?[]const u8 = null,
    /// From `--as`; skips version derivation.
    version_override: ?[]const u8 = null,
    /// From `--all`.
    all: bool = false,
    /// From `--date`.
    date_override: ?[]const u8 = null,
    /// From `--tag-prefix`.
    tag_prefix: ?[]const u8 = null,
    parse_merges: bool = false,
    include_unconventional: bool = false,
    force: bool = false,
    interactive: bool = false,
    /// Today's date, YYYY-MM-DD; passed in so tests are deterministic.
    today: []const u8,
    /// Reads a file relative to the repo root, or null when absent.
    read_file: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]u8,
    /// Cheap existence check; no allocation, used by detection.
    exists_file: *const fn (ctx: *anyopaque, path: []const u8) bool,
    ctx: *anyopaque,
};

pub const Error = error{
    OutOfMemory,
    NoRepo,
    NoChangelog,
    FragmentsOnly,
    NotMarkdown,
    Unparsable,
    SectionExists,
    GitFailed,
    GitMissing,
} || std.Io.Writer.Error;

pub fn build(allocator: std.mem.Allocator, req: Request) Error!Plan {
    const runner = req.runner;

    var notices: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (notices.items) |n| allocator.free(n);
        notices.deinit(allocator);
    }

    const root = git.worktree.root(runner) catch |err| return mapGit(err);

    // --- the file -------------------------------------------------------
    var probe_ctx = ProbeCtx{ .req = &req };
    const probe = detect.Probe{ .ctx = &probe_ctx, .exists = ProbeCtx.existsFn, .read = ProbeCtx.readFn };
    const forced = if (req.forced_file) |f| f else if (std.mem.eql(u8, req.cfg.changelog.file, "auto")) null else req.cfg.changelog.file;
    const found = try detect.detect(allocator, probe, forced);
    defer {
        for (found.ranked) |c| allocator.free(c.path);
        found.deinit(allocator);
    }
    if (found.fragment_dir) |d| {
        try notes(&notices, allocator, "found a fragment changelog ({s}); chgl does not read fragments yet", .{d});
    }
    const candidate = found.chosen orelse {
        if (found.fragment_dir != null) return error.FragmentsOnly;
        return error.NoChangelog;
    };
    if (!candidate.format.writable()) {
        try notes(&notices, allocator, "{s} is not a Markdown changelog; chgl only writes Markdown", .{candidate.path});
        return error.NotMarkdown;
    }
    const file_path = candidate.path;
    const original: []const u8 = req.read_file(req.ctx, allocator, file_path) orelse blk: {
        try notes(&notices, allocator, "{s} does not exist yet; it will be created", .{file_path});
        break :blk try allocator.dupe(u8, "");
    };
    errdefer allocator.free(original);
    const existed = original.len != 0;

    const doc = try changelog.parse.parse(allocator, original);
    errdefer doc.deinit(allocator);

    // --- the range ------------------------------------------------------
    const head_hash = headHash(allocator, runner) orelse return error.NoRepo;
    defer allocator.free(head_hash);
    const head: []const u8 = head_hash;
    var range = Range{};
    var base_tag: ?tags.Tag = null;
    const style: semver.TagStyle = if (req.tag_prefix) |p| .{ .prefix = p } else blk: {
        if (req.since) |s| {
            // Infer from the given tag so `--since 0.7.0` implies a bare style.
            break :blk semver.inferStyle(s);
        }
        const all_tags = tags.listAll(runner) catch &[_]tags.Tag{};
        const sel = tags.select(runner, all_tags, head);
        // The selected tag borrows `all_tags`; copy the name before freeing.
        if (sel.latest) |t| {
            base_tag = .{ .name = allocator.dupe(u8, t.name) catch "", .commit = t.commit, .version = t.version };
        }
        tags.freeAll(runner.allocator, all_tags);
        break :blk sel.style;
    };

    if (git.isShallow(runner)) {
        try notes(&notices, allocator, "this is a shallow clone; tags and history may be missing (use `git fetch --unshallow`)", .{});
    }

    if (req.since) |s| {
        range.from_tag = s;
        range.description = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{s});
    } else if (req.all) {
        range.whole_history = true;
        range.description = try allocator.dupe(u8, "whole history");
    } else if (base_tag) |t| {
        range.from_tag = t.name;
        range.description = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{t.name});
    } else {
        range.whole_history = true;
        range.description = try allocator.dupe(u8, "whole history");
        try notes(&notices, allocator, "no release tag found; listing the whole history (set a tag, or pass --since)", .{});
    }

    var commits = log.read(runner, .{
        .from = range.from_tag,
        .max = if (range.whole_history) req.cfg.changelog.max_commits else 0,
        .skip_merges = false,
    }) catch |err| return mapGit(err);
    defer commits.deinit(runner.allocator);

    // --- entries --------------------------------------------------------
    var release = try entry_mod.build(allocator, commits.commits, .{
        .parse_merges = req.parse_merges,
        .interactive = req.interactive,
        .exclude = req.cfg.changelog.exclude,
    });
    errdefer release.deinit(allocator);

    if (range.whole_history and commits.commits.len >= req.cfg.changelog.max_commits) {
        try notes(&notices, allocator, "history capped at {d} commits (changelog.max_commits)", .{req.cfg.changelog.max_commits});
    }
    const unconventional = release.count(.skip);
    var unconventional_count: usize = 0;
    for (release.entries.items) |e| {
        if (e.reason == .unconventional) unconventional_count += 1;
    }
    if (unconventional_count != 0 and !req.interactive) {
        try notes(&notices, allocator, "{d} commit(s) are not Conventional Commits and were skipped; pass --include-unconventional to list them", .{unconventional_count});
    }
    _ = unconventional;

    // --- the file's own unreleased content ------------------------------
    const placement = changelog.edit.place(allocator, doc, req.cfg.changelog.unreleased == .absorb) catch |err| switch (err) {
        error.Unparsable => {
            try notes(&notices, allocator, "{s} has no version headings; refusing to guess where a release section belongs", .{file_path});
            return error.Unparsable;
        },
        else => return err,
    };
    errdefer allocator.free(placement.absorbed);
    try absorbIntoRelease(allocator, &release, placement.absorbed);

    // --- version --------------------------------------------------------
    var version_source: ?source.Source = null;
    errdefer if (version_source) |vs| {
        allocator.free(vs.path);
        allocator.free(vs.version);
    };
    var current_version: ?semver.Semver = null;
    if (readVersionSource(allocator, req, &version_source)) |_| {} else |_| {
        version_source = null;
    }
    if (version_source) |vs| current_version = semver.Semver.parse(vs.version);

    var version: ?semver.Semver = null;
    if (req.version_override) |text| {
        version = semver.parseWithStyle(style, text);
    } else if (current_version) |cur| {
        version = entry_mod.nextVersion(cur, release, req.cfg.version.bump);
    }

    // Refuse to write the same release twice: a second run would otherwise
    // duplicate every entry (the first run's section is now the newest one, so
    // the range is empty and the same version is derived again).
    // `--force` is the explicit override.
    if (!req.force) {
        if (version) |v| {
            var label_buf: [64]u8 = undefined;
            if (doc.hasLabel(try v.render(&label_buf))) return error.SectionExists;
        }
    }

    const date = req.date_override orelse req.today;
    var heading_buf: [512]u8 = undefined;
    var heading_fbs = std.Io.Writer.fixed(&heading_buf);
    if (version) |v| {
        var vbuf: [64]u8 = undefined;
        try heading_fbs.print("## [{s}] - {s}", .{ try v.render(&vbuf), date });
    } else {
        try heading_fbs.print("## [{s}]", .{"Unreleased"});
        try notes(&notices, allocator, "no version source found; writing an [Unreleased] heading (pass --as <VERSION>)", .{});
    }
    const heading = try allocator.dupe(u8, heading_fbs.buffered());
    errdefer allocator.free(heading);

    // The file's own vocabulary, so `Features` stays `Features`.
    var vocab: std.ArrayList([]const u8) = .empty;
    errdefer vocab.deinit(allocator);
    for (doc.sections) |s| {
        for (s.groups) |g| {
            if (Group.fromTitle(g.name) != null) try vocab.append(allocator, g.name);
        }
    }

    var plan = Plan{
        .allocator = allocator,
        .repo_root = try allocator.dupe(u8, root),
        .created = !existed,
        .file_path = try allocator.dupe(u8, file_path),
        .format = candidate.format,
        .original = original,
        .exists = existed,
        .doc = doc,
        .placement = placement,
        .release = release,
        .total_commits = commits.commits.len,
        .range = range,
        .current_version = current_version,
        .version = version,
        .version_style = style,
        .version_source = version_source,
        .date = date,
        .heading = heading,
        .vocabulary = try vocab.toOwnedSlice(allocator),
    };
    plan.notices = notices;
    return plan;
}

fn notes(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try list.append(allocator, try std.fmt.allocPrint(allocator, fmt, args));
}

/// Add the file's `[Unreleased]` bullets as entries. The file's wording wins:
/// these are `from_file`, keep their text, and are never reclassified.
fn absorbIntoRelease(allocator: std.mem.Allocator, release: *Release, absorbed: []const changelog.Placement.AbsorbedGroup) !void {
    for (absorbed) |g| {
        const group = Group.fromTitle(g.name) orelse .other;
        var lines = std.mem.splitScalar(u8, g.body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (!std.mem.startsWith(u8, line, "- ") and !std.mem.startsWith(u8, line, "* ")) continue;
            const text = std.mem.trim(u8, line[2..], " \t");
            if (text.len == 0) continue;
            try release.entries.append(allocator, .{
                .subject = text,
                .short_hash = "",
                .parsed = .{
                    .kind = .other,
                    .type_name = "",
                    .scope = null,
                    .description = text,
                    .breaking = false,
                    .breaking_note = null,
                    .refs = &.{},
                },
                .group = group,
                .type_group = group,
                .state = .keep,
                .reason = .none,
                .breaking = false,
                .from_file = true,
            });
        }
    }
}

fn readVersionSource(allocator: std.mem.Allocator, req: Request, out: *?source.Source) error{OutOfMemory}!?source.Source {
    const explicit = req.cfg.version.source;
    var candidates: []const source.Kind = &.{};
    var chosen_file: ?[]const u8 = null;
    if (std.mem.eql(u8, explicit, "none")) return null;
    if (std.mem.eql(u8, explicit, "cargo")) {
        candidates = &.{.cargo};
    } else if (std.mem.eql(u8, explicit, "npm")) {
        candidates = &.{.npm};
    } else if (std.mem.eql(u8, explicit, "pyproject")) {
        candidates = &.{.pyproject};
    } else if (std.mem.eql(u8, explicit, "file")) {
        candidates = &.{.file};
        if (req.cfg.version.path.len != 0) chosen_file = req.cfg.version.path;
    } else {
        candidates = &.{ .cargo, .npm, .pyproject, .file };
    }

    for (candidates) |kind| {
        const path = chosen_file orelse kind.filename();
        const text = req.read_file(req.ctx, allocator, path) orelse continue;
        defer allocator.free(text);
        const version = source.readFrom(kind, text) catch continue;
        const parsed = semver.Semver.parse(version) orelse continue;
        const s = source.Source{
            .kind = kind,
            .path = try allocator.dupe(u8, path),
            .version = try allocator.dupe(u8, version),
            .parsed = parsed,
        };
        out.* = s;
        return s;
    }
    return null;
}

fn headHash(allocator: std.mem.Allocator, runner: git.Runner) ?[]u8 {
    const out = runner.run(&.{ "git", "rev-parse", "HEAD" }, true) catch return null;
    defer out.deinit(runner.allocator);
    if (!out.ok()) return null;
    return allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \r\n")) catch null;
}

/// Byte of glue: detection speaks callbacks, `Request` speaks callbacks with a
/// context. Both must use the *same* context, or `ctx` is cast to the wrong
/// type — which is exactly what a segfault here would mean.
const ProbeCtx = struct {
    req: *const Request,

    fn existsFn(ctx: *anyopaque, path: []const u8) bool {
        const self: *ProbeCtx = @ptrCast(@alignCast(ctx));
        return self.req.exists_file(self.req.ctx, path);
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        const self: *ProbeCtx = @ptrCast(@alignCast(ctx));
        return self.req.read_file(self.req.ctx, allocator, path);
    }
};

fn mapGit(err: anytype) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GitMissing => error.GitMissing,
        else => error.GitFailed,
    };
}

test "plan text survives the commit log buffer" {
    const a = std.testing.allocator;
    const commits = [_]log.Record{.{
        .hash = "a",
        .short = "aaaaaaa",
        .timestamp = 0,
        .author_name = "A",
        .author_email = "a@x",
        .parents = "p",
        .subject = "feat: one",
        .body = "",
    }};
    var release = try entry_mod.build(a, &commits, .{});
    defer release.deinit(a);
    try std.testing.expectEqualStrings("one", release.entries.items[0].text());
}

test "clearing an empty unreleased section never touches the new heading" {
    // Regression: the clear ran on the *post-insert* bytes using offsets from
    // the pre-insert file, which cut the heading and re-emitted [Unreleased].
    const a = std.testing.allocator;
    const text =
        "# Changelog\n\nIntro.\n\n## [Unreleased]\n\n" ++
        "[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD\n" ++
        "[0.1.0]: https://github.com/o/r/compare/v0.0.1...v0.1.0\n";
    const doc = try changelog.parse.parse(a, text);
    defer doc.deinit(a);
    const placement = try changelog.edit.place(a, doc, true);
    defer a.free(placement.absorbed);
    try std.testing.expect(placement.unreleased != null);

    const cleared = try changelog.edit.clearUnreleased(a, text, doc, .lf);
    defer a.free(cleared);
    const out = try changelog.edit.insert(a, cleared, placement, .{
        .heading = "## [0.2.0] - 2026-11-15",
        .body = "### Added\n\n- y",
        .eol = .lf,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "## [0.2.0] - 2026-11-15") != null);
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "## [Unreleased]")) |at| {
        count += 1;
        idx = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
