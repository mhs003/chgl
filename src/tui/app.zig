//! The interactive editor's state and its layout.
//!
//! Everything here is a pure function of the state. Given a `State`, a size and
//! a key, the app produces a new state and a `Buffer`; the terminal layer only
//! copies that buffer out. No screen, no input device, no globals — which is
//! why the whole interface can be tested in a unit test.

const std = @import("std");
const plan_mod = @import("../plan.zig");
const entry_mod = @import("../release/entry.zig");
const render = @import("../render.zig");
const cell = @import("cell.zig");

pub const RenderError = error{ OutOfMemory, WriteFailed };

pub const Mode = enum {
    /// The entry list: what ships, what does not, and why.
    list,
    /// The rendered section, exactly as it would be written.
    preview,
    /// Key reference.
    help,
    /// The apply confirmation.
    confirm,
};

pub const Focus = enum { chrome, entries };

/// What the app needs to show and change. `plan.Plan` is one implementation;
/// tests build a tiny one without git or files.
pub const View = struct {
    pub const VTable = struct {
        entries: *const fn (ctx: *anyopaque) []entry_mod.Entry,
        file_path: *const fn (ctx: *anyopaque) []const u8,
        format_name: *const fn (ctx: *anyopaque) []const u8,
        range_description: *const fn (ctx: *anyopaque) []const u8,
        total_commits: *const fn (ctx: *anyopaque) usize,
        heading: *const fn (ctx: *anyopaque) []const u8,
        version_line: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
        rendered_file: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) RenderError![]u8,
        apply_hint: *const fn (ctx: *anyopaque) []const u8,
        create_tag: *const fn (ctx: *anyopaque) bool,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn entries(self: View) []entry_mod.Entry {
        return self.vtable.entries(self.ctx);
    }
    pub fn filePath(self: View) []const u8 {
        return self.vtable.file_path(self.ctx);
    }
    pub fn formatName(self: View) []const u8 {
        return self.vtable.format_name(self.ctx);
    }
    pub fn rangeDescription(self: View) []const u8 {
        return self.vtable.range_description(self.ctx);
    }
    pub fn totalCommits(self: View) usize {
        return self.vtable.total_commits(self.ctx);
    }
    pub fn heading(self: View) []const u8 {
        return self.vtable.heading(self.ctx);
    }
    pub fn versionLine(self: View, buf: []u8) []const u8 {
        return self.vtable.version_line(self.ctx, buf);
    }
    pub fn renderedFile(self: View, allocator: std.mem.Allocator) RenderError![]u8 {
        return self.vtable.rendered_file(self.ctx, allocator);
    }
    pub fn applyHint(self: View) []const u8 {
        return self.vtable.apply_hint(self.ctx);
    }
};

pub const State = struct {
    view: View,
    allocator: std.mem.Allocator,
    mode: Mode = .list,
    /// Index into `plan.release.entries.items`.
    cursor: usize = 0,
    scroll: usize = 0,
    /// Set when the user asked to apply and the confirmation is showing.
    about_to_apply: bool = false,
    /// The last notice to show in the footer (e.g. "writing").
    status: []const u8 = "",
    show_skipped: bool = true,
    /// Path edited by the version prompt, if the user opened it.
    editing_version: bool = false,
    version_input: std.ArrayList(u8) = .empty,
    /// What the app decided the run should do when the user quits the editor.
    outcome: Outcome = .cancelled,
    /// What applying will do, chosen on the confirmation screen.
    commit: bool = false,
    create_tag: bool = false,

    pub const Outcome = enum {
        cancelled,
        write,
        write_commit,
        write_commit_tag,
    };

    /// The outcome implied by the commit/tag choices on the confirm screen.
    pub fn chosenOutcome(self: State) Outcome {
        if (self.create_tag) return .write_commit_tag;
        if (self.commit) return .write_commit;
        return .write;
    }

    pub fn init(view: View, allocator: std.mem.Allocator) State {
        return .{ .view = view, .allocator = allocator };
    }

    pub fn entryCount(self: State) usize {
        return self.view.entries().len;
    }

    pub fn currentEntry(self: State) ?*entry_mod.Entry {
        const items = self.view.entries();
        if (self.cursor >= items.len) return null;
        return &items[self.cursor];
    }

    /// Space/`k`: keep ↔ skip. `Ask` becomes keep on the first press so one
    /// key is enough to include something the tool was unsure about.
    pub fn toggle(self: *State) void {
        const e = self.currentEntry() orelse return;
        e.state = switch (e.state) {
            .keep => .skip,
            .skip, .ask => .keep,
        };
    }

    pub fn move(self: *State, delta: isize) void {
        const n = self.entryCount();
        if (n == 0) return;
        const cur: isize = @intCast(self.cursor);
        var next = cur + delta;
        if (next < 0) next = 0;
        if (next >= @as(isize, @intCast(n))) next = @as(isize, @intCast(n)) - 1;
        self.cursor = @intCast(next);
    }
};

/// Key names the app understands, already decoded from bytes.
pub const Key = union(enum) {
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    enter,
    escape,
    space,
    tab,
    char: u8,
    ctrl_c,
};

pub const Action = union(enum) {
    none,
    /// The user finished; caller applies `state.outcome`.
    quit: State.Outcome,
    redraw,
};

/// Apply one key. Returns the outcome to act on.
pub fn handleKey(state: *State, key: Key) Action {
    switch (state.mode) {
        .help => {
            if (key == .escape or key == .enter or isChar(key, 'q') or key == .char) state.mode = .list;
            return .{ .redraw = {} };
        },
        .confirm => switch (key) {
            .char => |c| switch (c) {
                'y' => return .{ .quit = state.chosenOutcome() },
                'n', 'q' => {
                    state.mode = .list;
                    return .{ .redraw = {} };
                },
                // The screen says what will happen; these choose it. Without
                // them, committing or tagging meant relaunching with flags,
                // which defeats the point of confirming here.
                'c' => {
                    state.commit = !state.commit;
                    // A tag without a commit would tag a tree the changelog
                    // was never written into.
                    if (!state.commit) state.create_tag = false;
                    return .{ .redraw = {} };
                },
                't' => {
                    state.create_tag = !state.create_tag;
                    if (state.create_tag) state.commit = true;
                    return .{ .redraw = {} };
                },
                else => return .{ .redraw = {} },
            },
            .escape, .ctrl_c => {
                state.mode = .list;
                return .{ .redraw = {} };
            },
            else => return .{ .redraw = {} },
        },
        .preview => switch (key) {
            .char => |c| switch (c) {
                'p', 'q' => state.mode = .list,
                'j' => state.scroll += 1,
                'k' => state.scroll -|= 1,
                else => {},
            },
            .down => state.scroll += 1,
            .up => state.scroll -|= 1,
            .page_down => state.scroll += 10,
            .page_up => state.scroll -|= 10,
            .escape => state.mode = .list,
            .ctrl_c => return .{ .quit = .cancelled },
            else => {},
        },
        .list => switch (key) {
            .up => state.move(-1),
            .down => state.move(1),
            .page_up => state.move(-10),
            .page_down => state.move(10),
            .home => state.cursor = 0,
            .end => state.cursor = if (state.entryCount() == 0) 0 else state.entryCount() - 1,
            .space, .tab => state.toggle(),
            .char => |c| switch (c) {
                'j' => state.move(1),
                'k' => state.move(-1),
                'g' => state.cursor = 0,
                'G' => state.cursor = if (state.entryCount() == 0) 0 else state.entryCount() - 1,
                'p' => {
                    state.mode = .preview;
                    state.scroll = 0;
                },
                'a' => {
                    // Confirming always means "apply what this screen shows".
                    // Seeded from the flags the user started with; without this
                    // the state kept the cancel outcome it was initialised with
                    // (no flags means write=false), so `y` quit as if nothing
                    // had been asked for.
                    state.commit = state.outcome == .write_commit or state.outcome == .write_commit_tag;
                    state.create_tag = state.outcome == .write_commit_tag;
                    state.mode = .confirm;
                },
                '?' => state.mode = .help,
                'q' => return .{ .quit = .cancelled },
                else => {},
            },
            .ctrl_c => return .{ .quit = .cancelled },
            else => {},
        },
    }
    return .{ .redraw = {} };
}

fn isChar(key: Key, c: u8) bool {
    return switch (key) {
        .char => |x| x == c,
        else => false,
    };
}

/// Set the outcome implied by the flags the user started with, so `a` asks once
/// and applies the same set the CLI would have applied.
pub fn defaultOutcome(write: bool, commit: bool, create_tag: bool) State.Outcome {
    if (!write) return .cancelled;
    if (create_tag) return .write_commit_tag;
    if (commit) return .write_commit;
    return .write;
}

// ---------------------------------------------------------------- rendering

/// The frame is plain ASCII on purpose: it renders identically in every
/// terminal, every font, over SSH, in a monospace-free environment, and in a
/// screenshot. There is no "fancy" variant to fall out of sync with.
pub const chrome = struct {
    pub const corner = "+";
    pub const h = "-";
    pub const v = "|";
    pub const cursor = ">";
};

/// Render the whole frame. `width`/`height` below 40x10 still produce *some*
/// output rather than panicking, so a tiny terminal degrades instead of dying.
pub fn draw(state: *State, allocator: std.mem.Allocator, width: u16, height: u16) !cell.Buffer {
    var buf = try cell.Buffer.init(allocator, width, height);
    errdefer buf.deinit();

    if (width < 40 or height < 8) {
        _ = buf.put(0, 0, "window too small: need at least 40x8", .warn);
        return buf;
    }

    switch (state.mode) {
        .list => try drawList(state, &buf),
        .preview => try drawPreview(state, &buf),
        .help => drawHelp(&buf),
        .confirm => drawConfirm(state, &buf),
    }
    return buf;
}

fn frameTop(buf: *cell.Buffer, title: []const u8) void {
    _ = buf.put(0, 0, chrome.corner, .dim);
    var x: u16 = 1;
    x = buf.put(x, 0, " ", .dim);
    x = buf.put(x, 0, title, .accent);
    x = buf.put(x, 0, " ", .dim);
    while (x < buf.width - 1) : (x += 1) {
        _ = buf.put(x, 0, chrome.h, .dim);
    }
    _ = buf.put(buf.width - 1, 0, chrome.corner, .dim);
}

fn frameBottom(buf: *cell.Buffer, hint: []const u8) void {
    const y = buf.height - 1;
    _ = buf.put(0, y, chrome.corner, .dim);
    var x: u16 = 1;
    x = buf.put(x, y, chrome.h, .dim);
    x = buf.put(x, y, " ", .dim);
    // Leave a space on both sides of the hint so it cannot touch the border.
    const room = buf.width -| 4;
    const text = if (hint.len > room) hint[0..room] else hint;
    x = buf.put(x, y, text, .dim);
    while (x + 1 < buf.width - 1) : (x += 1) {
        _ = buf.put(x, y, chrome.h, .dim);
    }
    _ = buf.put(buf.width - 1, y, chrome.corner, .dim);
}

fn drawList(state: *State, buf: *cell.Buffer) !void {
    var line_buf: [512]u8 = undefined;
    frameTop(buf, "chgl");

    // Header: the decisions the tool made, each with its reason.
    var y: u16 = 1;
    const view = state.view;
    var fbs = std.Io.Writer.fixed(&line_buf);
    try fbs.print(" {s}  {s}", .{ view.filePath(), view.formatName() });
    _ = buf.put(1, y, fbs.buffered(), .default);

    y += 1;
    fbs = std.Io.Writer.fixed(&line_buf);
    try fbs.print(" {s}  ", .{view.rangeDescription()});
    var vbuf: [128]u8 = undefined;
    try fbs.writeAll(view.versionLine(&vbuf));
    const entries = view.entries();
    var keep: usize = 0;
    var skip: usize = 0;
    var ask: usize = 0;
    for (entries) |e| switch (e.state) {
        .keep => keep += 1,
        .skip => skip += 1,
        .ask => ask += 1,
    };
    try fbs.print("  {d} commits  {d} keep  {d} skip  {d} ask", .{ view.totalCommits(), keep, skip, ask });
    _ = buf.put(1, y, fbs.buffered(), .default);

    y += 1;
    _ = buf.put(0, y, chrome.v, .dim);
    y += 1;

    const bottom = buf.height - 1;
    if (state.entryCount() == 0) {
        _ = buf.put(2, y, "nothing in range: no commits since the last release", .warn);
    }

    // Keep the cursor visible.
    const visible = bottom -| y - 1;
    if (visible > 0) {
        if (state.cursor < state.scroll) state.scroll = state.cursor;
        if (state.cursor >= state.scroll + visible) state.scroll = state.cursor - visible + 1;
    }

    // Every state has a word, not just a colour; this line says what the
    // words mean. It sits above the rows so it never eats one.
    var legend_buf: [128]u8 = undefined;
    const legend = std.fmt.bufPrint(&legend_buf, " Keep = written   Skip = left out (reason on the right)   Ask = decide", .{}) catch "";
    _ = buf.put(2, y, legend, .dim);
    y += 1;

    var i = state.scroll;
    var row = y;
    while (i < state.entryCount() and row < bottom) : ({
        i += 1;
        row += 1;
    }) {
        const e = state.view.entries()[i];
        const selected = i == state.cursor;
        const state_text = e.state.label();
        const color: cell.Color = switch (e.state) {
            .keep => .good,
            .skip => .dim,
            .ask => .warn,
        };
        fbs = std.Io.Writer.fixed(&line_buf);
        try fbs.print(" {s} {s:<4} {s:<16} {s}", .{
            if (selected) chrome.cursor else " ",
            state_text,
            @tagName(e.group),
            e.text(),
        });
        _ = buf.put(1, row, fbs.buffered(), color);
        if (selected) buf.highlight(0, row, buf.width - 2);
        if (e.reason != .none) {
            // The reason is what makes a skip reviewable.
            var rbuf: [64]u8 = undefined;
            const reason = std.fmt.bufPrint(&rbuf, "({s})", .{e.reason.label()}) catch "";
            const room: u16 = @intCast(@min(reason.len, @as(usize, buf.width)));
            if (buf.width > room + 2) {
                _ = buf.put(buf.width - room - 2, row, reason, .dim);
            }
        }
    }

    var hint: []const u8 = "space keep/skip  p preview  a apply  ? help  q quit";
    if (state.status.len != 0) hint = state.status;
    frameBottom(buf, hint);
}

fn drawPreview(state: *State, buf: *cell.Buffer) !void {
    frameTop(buf, "preview: what will be written");
    const rendered = try state.view.renderedFile(state.allocator);
    defer state.allocator.free(rendered);

    const bottom = buf.height - 1;
    var y: u16 = 1;
    var it = std.mem.splitScalar(u8, rendered, '\n');
    var skip = state.scroll;
    while (it.next()) |line| {
        if (skip != 0) {
            skip -= 1;
            continue;
        }
        if (y + 1 >= bottom) break;
        _ = buf.put(1, y, line, .default);
        y += 1;
    }
    frameBottom(buf, "j/k scroll  p back  (this is the exact file content)");
}

fn drawHelp(buf: *cell.Buffer) void {
    frameTop(buf, "keys");
    const lines = [_][2][]const u8{
        .{ "j / k, up / down", "move between entries" },
        .{ "space, tab", "keep or skip the selected entry" },
        .{ "g / G, home / end", "first / last entry" },
        .{ "p", "preview the exact file that will be written" },
        .{ "a", "apply: write, then commit and tag as asked" },
        .{ "q, esc", "quit without writing anything" },
        .{ "?", "this help" },
    };
    var y: u16 = 2;
    for (lines) |l| {
        if (y + 1 >= buf.height) break;
        _ = buf.put(2, y, l[0], .accent);
        _ = buf.put(28, y, l[1], .default);
        y += 1;
    }
    _ = buf.put(2, y + 1, "Entries marked Skip are not written; Ask means chgl was unsure.", .dim);
    frameBottom(buf, "press any key to go back");
}

fn drawConfirm(state: *State, buf: *cell.Buffer) void {
    frameTop(buf, "apply");
    var line_buf: [512]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&line_buf);
    fbs.print(" {s}", .{state.view.heading()}) catch {};
    _ = buf.put(2, 2, fbs.buffered(), .accent);

    var y: u16 = 4;
    fbs = std.Io.Writer.fixed(&line_buf);
    fbs.print(" write {s}", .{state.view.filePath()}) catch {};
    _ = buf.put(2, y, fbs.buffered(), .good);

    y += 1;
    const mode_text = switch (state.chosenOutcome()) {
        .cancelled, .write => " commit: no",
        .write_commit => " commit: yes",
        .write_commit_tag => " commit: yes, tag: yes",
    };
    _ = buf.put(2, y, mode_text, .default);

    y += 2;
    var keep: usize = 0;
    var skip: usize = 0;
    for (state.view.entries()) |e| switch (e.state) {
        .keep => keep += 1,
        .skip => skip += 1,
        .ask => {},
    };
    fbs = std.Io.Writer.fixed(&line_buf);
    fbs.print(" {d} entries, {d} skipped", .{ keep, skip }) catch {};
    _ = buf.put(2, y, fbs.buffered(), .dim);

    frameBottom(buf, "y apply   c commit   t tag   n back   (nothing is written until you answer)");
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const Fake = struct {
    entries_buf: []entry_mod.Entry,
    heading_text: []const u8 = "## [0.8.0] - 2026-11-15",
    file: []const u8 = "CHANGELOG.md",
    range: []const u8 = "v0.7.3..HEAD",
    version: []const u8 = "0.7.3 -> 0.8.0",
    rendered: []const u8 = "## [0.8.0]\n\n### Added\n\n- one\n",
    commits: usize = 3,

    fn view(self: *Fake) View {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = View.VTable{
        .entries = e,
        .file_path = fp,
        .format_name = fn_,
        .range_description = rd,
        .total_commits = tc,
        .heading = hd,
        .version_line = vl,
        .rendered_file = rf,
        .apply_hint = ah,
        .create_tag = ct,
    };

    fn e(ctx: *anyopaque) []entry_mod.Entry {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.entries_buf;
    }
    fn fp(ctx: *anyopaque) []const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.file;
    }
    fn fn_(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return "Keep a Changelog";
    }
    fn rd(ctx: *anyopaque) []const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.range;
    }
    fn tc(ctx: *anyopaque) usize {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.commits;
    }
    fn hd(ctx: *anyopaque) []const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.heading_text;
    }
    fn vl(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(buf[0..self.version.len], self.version);
        return buf[0..self.version.len];
    }
    fn rf(ctx: *anyopaque, allocator: std.mem.Allocator) RenderError![]u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.rendered);
    }
    fn ah(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return "";
    }
    fn ct(ctx: *anyopaque) bool {
        _ = ctx;
        return false;
    }
};

fn testEntry(desc: []const u8, group: entry_mod.Group, state: entry_mod.State) entry_mod.Entry {
    return .{
        .subject = desc,
        .short_hash = "abc1234",
        .parsed = .{ .kind = .feat, .type_name = "feat", .scope = null, .description = desc, .breaking = false, .breaking_note = null, .refs = &.{} },
        .group = group,
        .type_group = group,
        .state = state,
        .reason = if (state == .skip) .unconventional else .none,
        .breaking = false,
    };
}

/// Whole screen as text, for assertions that do not care about columns.
fn screenText(buf: *cell.Buffer, out: []u8) []const u8 {
    var line: [512]u8 = undefined;
    var fbs = std.Io.Writer.fixed(out);
    var y: u16 = 0;
    while (y < buf.height) : (y += 1) {
        const text = buf.rowText(y, &line);
        if (text.len == 0) continue;
        fbs.print("{s}\n", .{text}) catch break;
    }
    return fbs.buffered();
}

test "navigation clamps at both ends" {
    var entries = [_]entry_mod.Entry{
        testEntry("one", .added, .keep),
        testEntry("two", .fixed, .skip),
        testEntry("three", .other, .ask),
    };
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);

    state.move(-1);
    try testing.expectEqual(@as(usize, 0), state.cursor);
    state.move(100);
    try testing.expectEqual(@as(usize, 2), state.cursor);
    state.move(-100);
    try testing.expectEqual(@as(usize, 0), state.cursor);
}

test "space keeps, skips, and rescues an unsure entry" {
    var entries = [_]entry_mod.Entry{
        testEntry("one", .added, .keep),
        testEntry("two", .other, .ask),
    };
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);

    _ = handleKey(&state, .space);
    try testing.expectEqual(entry_mod.State.skip, entries[0].state);

    state.move(1);
    _ = handleKey(&state, .space);
    try testing.expectEqual(entry_mod.State.keep, entries[1].state);
}

test "the list shows every state as a word, with the reason" {
    var entries = [_]entry_mod.Entry{
        testEntry("add a thing", .added, .keep),
        testEntry("wip", .other, .ask),
        testEntry("noise", .other, .skip),
    };
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);

    var buf = try draw(&state, testing.allocator, 80, 24);
    defer buf.deinit();
    var all: [8192]u8 = undefined;
    const screen = screenText(&buf, &all);
    try testing.expect(std.mem.indexOf(u8, screen, "Keep") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "Ask") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "Skip") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "not a conventional commit") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "CHANGELOG.md") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "v0.7.3..HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "0.7.3 -> 0.8.0") != null);
}

test "a tiny terminal degrades instead of crashing" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    var buf = try draw(&state, testing.allocator, 20, 4);
    defer buf.deinit();
    var line: [64]u8 = undefined;
    const text = buf.rowText(0, &line);
    try testing.expect(std.mem.indexOf(u8, text, "too small") != null);
}

test "help opens and closes, and lists the real keys" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    _ = handleKey(&state, .{ .char = '?' });
    try testing.expectEqual(Mode.help, state.mode);

    var buf = try draw(&state, testing.allocator, 80, 24);
    defer buf.deinit();
    var all: [8192]u8 = undefined;
    const screen = screenText(&buf, &all);
    try testing.expect(std.mem.indexOf(u8, screen, "preview the exact file") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "quit without writing") != null);

    _ = handleKey(&state, .escape);
    try testing.expectEqual(Mode.list, state.mode);
}

test "quit never writes unless the user applied" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    const action = handleKey(&state, .{ .char = 'q' });
    try testing.expectEqual(Action{ .quit = .cancelled }, action);
}

test "apply requires a confirmation" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    state.outcome = .write;
    _ = handleKey(&state, .{ .char = 'a' });
    try testing.expectEqual(Mode.confirm, state.mode);
    _ = handleKey(&state, .escape);
    try testing.expectEqual(Mode.list, state.mode);
    _ = handleKey(&state, .{ .char = 'a' });
    const action = handleKey(&state, .{ .char = 'y' });
    try testing.expectEqual(Action{ .quit = .write }, action);
}

test "confirming with no flags still applies the write" {
    // Regression: opened with no flags, `outcome` starts as .cancelled because
    // nothing was asked for on the command line, so pressing `a` then `y` quit
    // as a cancel and wrote nothing. The confirm screen looked identical either
    // way, which is why only an outcome-level test catches it.
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    try testing.expectEqual(State.Outcome.cancelled, state.outcome);

    _ = handleKey(&state, .{ .char = 'a' });
    const action = handleKey(&state, .{ .char = 'y' });
    try testing.expectEqual(Action{ .quit = .write }, action);
}

test "the confirm screen can choose commit and tag" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };

    var state = State.init(fake.view(), testing.allocator);
    _ = handleKey(&state, .{ .char = 'a' });
    _ = handleKey(&state, .{ .char = 'c' });
    try testing.expectEqual(Action{ .quit = .write_commit }, handleKey(&state, .{ .char = 'y' }));

    // A tag implies a commit: tagging a tree the changelog never entered would
    // label the wrong content.
    state = State.init(fake.view(), testing.allocator);
    _ = handleKey(&state, .{ .char = 'a' });
    _ = handleKey(&state, .{ .char = 't' });
    try testing.expectEqual(Action{ .quit = .write_commit_tag }, handleKey(&state, .{ .char = 'y' }));

    // Turning the commit off must also drop the tag.
    state = State.init(fake.view(), testing.allocator);
    _ = handleKey(&state, .{ .char = 'a' });
    _ = handleKey(&state, .{ .char = 't' });
    _ = handleKey(&state, .{ .char = 'c' });
    try testing.expectEqual(Action{ .quit = .write }, handleKey(&state, .{ .char = 'y' }));
}

test "confirm shows the choice, not just the flags it started with" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    _ = handleKey(&state, .{ .char = 'a' });

    var buf = try draw(&state, testing.allocator, 80, 24);
    defer buf.deinit();
    var all: [8192]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screenText(&buf, &all), "commit: no") != null);

    _ = handleKey(&state, .{ .char = 'c' });
    var buf2 = try draw(&state, testing.allocator, 80, 24);
    defer buf2.deinit();
    var all2: [8192]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screenText(&buf2, &all2), "commit: yes") != null);
}

test "preview shows the exact file content" {
    var entries = [_]entry_mod.Entry{};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    _ = handleKey(&state, .{ .char = 'p' });
    try testing.expectEqual(Mode.preview, state.mode);
    var buf = try draw(&state, testing.allocator, 80, 24);
    defer buf.deinit();
    var all: [8192]u8 = undefined;
    const screen = screenText(&buf, &all);
    try testing.expect(std.mem.indexOf(u8, screen, "- one") != null);
}

test "the frame is pure ASCII, always" {
    var entries = [_]entry_mod.Entry{testEntry("x", .added, .keep)};
    var fake = Fake{ .entries_buf = &entries };
    var state = State.init(fake.view(), testing.allocator);
    var buf = try draw(&state, testing.allocator, 80, 24);
    defer buf.deinit();
    for (buf.cells) |c| {
        try testing.expect(c.ch < 0x80);
    }
}

// ------------------------------------------------------- plan integration

/// Adapt a real `Plan` to the view interface.
pub const PlanView = struct {
    plan: *plan_mod.Plan,
    links: render.LinkStyle = .{},

    pub fn view(self: *PlanView) View {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = View.VTable{
        .entries = entriesFn,
        .file_path = fileFn,
        .format_name = formatFn,
        .range_description = rangeFn,
        .total_commits = totalFn,
        .heading = headingFn,
        .version_line = versionFn,
        .rendered_file = renderedFn,
        .apply_hint = hintFn,
        .create_tag = tagFn,
    };

    fn entriesFn(ctx: *anyopaque) []entry_mod.Entry {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.release.entries.items;
    }
    fn fileFn(ctx: *anyopaque) []const u8 {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.file_path;
    }
    fn formatFn(ctx: *anyopaque) []const u8 {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.format.name();
    }
    fn rangeFn(ctx: *anyopaque) []const u8 {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.range.description;
    }
    fn totalFn(ctx: *anyopaque) usize {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.total_commits;
    }
    fn headingFn(ctx: *anyopaque) []const u8 {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.heading;
    }
    fn versionFn(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        var fbs = std.Io.Writer.fixed(buf);
        if (self.plan.current_version) |cur| {
            fbs.print("{d}.{d}.{d}", .{ cur.major, cur.minor, cur.patch }) catch {};
        } else {
            fbs.writeAll("-") catch {};
        }
        fbs.writeAll(" -> ") catch {};
        if (self.plan.version) |v| {
            fbs.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch {};
        } else {
            fbs.writeAll("Unreleased") catch {};
        }
        return fbs.buffered();
    }
    fn renderedFn(ctx: *anyopaque, allocator: std.mem.Allocator) RenderError![]u8 {
        _ = allocator; // the plan owns its allocator
        const self: *PlanView = @ptrCast(@alignCast(ctx));
        return self.plan.resultingFile(self.links) catch return error.OutOfMemory;
    }
    fn hintFn(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return "";
    }
    fn tagFn(ctx: *anyopaque) bool {
        _ = ctx;
        return false;
    }
};
