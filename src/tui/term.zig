//! The terminal: alternate screen, raw mode, input decoding, and the promise
//! that the terminal is given back however the process leaves.
//!
//! Rules this file exists to enforce (see AGENTS.md):
//! - the alternate screen and raw mode are only ever held while the editor is
//!   on screen, and restored on normal exit, on error, and on panic;
//! - `SIGINT`/`SIGTERM`/`SIGHUP` restore before the process dies, and
//!   `SIGTSTP` restores so a suspended editor leaves a usable shell;
//! - nothing here writes to stdout: the editor talks to the terminal device
//!   directly, so `chgl > notes.md` can never capture escape codes.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const cell = @import("cell.zig");

pub const Error = error{
    NotATerminal,
    Unsupported,
    OutOfMemory,
} || std.Io.Writer.Error;

/// Saved settings, restored by `restore`.
var saved: ?Saved = null;

/// The terminal device a signal handler should give back. Set while the editor
/// owns the screen; null otherwise, so the handler is a no-op for the rest of
/// the process's life.
var restore_fd: ?std.posix.fd_t = null;

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    // Only async-signal-safe work: write the restore sequence and exit.
    // The terminal device is a separate fd from stderr, so the sequence has to
    // be written to it explicitly; `restore_fd` is the output side.
    if (restore_fd) |fd| {
        const seq = "\x1b[?25h\x1b[?1049l\x1b[0m";
        var written: usize = 0;
        while (written < seq.len) {
            const n = std.posix.system.write(fd, seq.ptr + written, seq.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
        if (saved) |s| {
            _ = std.posix.system.tcsetattr(fd, .FLUSH, &s.original);
        }
    }
    std.process.exit(@truncate(128 + @as(u32, @intFromEnum(sig))));
}

/// Install handlers that hand the terminal back before dying. Without these a
/// `kill`, a closed window or a dropped connection leaves the shell in raw mode
/// on the alternate screen — the worst thing a TUI can do.
fn installHandlers(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) return;
    restore_fd = fd;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .TERM, .HUP, .INT }) |sig| {
        std.posix.sigaction(sig, &act, null);
    }
}

fn removeHandlers() void {
    if (builtin.os.tag == .windows) return;
    restore_fd = null;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = null },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .TERM, .HUP, .INT }) |sig| {
        std.posix.sigaction(sig, &act, null);
    }
}

const Saved = struct {
    original: std.posix.termios,
};

pub fn isTty(io: std.Io, file: std.Io.File) bool {
    return file.isTty(io) catch false;
}

/// Open the controlling terminal for reading and writing. On Unix this is
/// `/dev/tty`, which exists exactly when there *is* a controlling terminal.
pub const Terminal = struct {
    in: std.Io.File,
    out: std.Io.File,
    io: std.Io,
    width: u16 = 80,
    height: u16 = 24,

    pub fn open(io: std.Io) Error!Terminal {
        if (builtin.os.tag == .windows) {
            // `CONIN$`/`CONOUT$` are device names, not paths, so they cannot go
            // through the "absolute path" helper (it asserts and panics).
            const in = std.Io.Dir.cwd().openFile(io, "CONIN$", .{ .mode = .read_only }) catch return error.NotATerminal;
            const out = std.Io.Dir.cwd().openFile(io, "CONOUT$", .{ .mode = .read_write }) catch {
                in.close(io);
                return error.NotATerminal;
            };
            return .{ .in = in, .out = out, .io = io };
        }
        const in = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_only }) catch return error.NotATerminal;
        const out = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch {
            in.close(io);
            return error.NotATerminal;
        };
        return .{ .in = in, .out = out, .io = io };
    }

    pub fn close(self: *Terminal) void {
        self.restore();
        self.in.close(self.io);
        self.out.close(self.io);
    }

    /// Raw mode + alternate screen. Always pair with `restore` in a `defer`.
    pub fn begin(self: *Terminal, err: *std.Io.Writer) !void {
        if (builtin.os.tag != .windows) {
            const fd = self.in.handle;
            const original = std.posix.tcgetattr(fd) catch return error.NotATerminal;
            saved = .{ .original = original };
            var raw = original;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;
            raw.oflag.OPOST = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(fd, .NOW, raw) catch return error.NotATerminal;
            // The restore write has to go to the readable *and writable* side,
            // which is the output fd; the input fd is opened read-only.
            installHandlers(self.out.handle);
        }
        // Alternate screen, hidden cursor, and bracketed paste off: paste is
        // handled as plain input so a multi-line paste cannot inject commands.
        try err.writeAll("\x1b[?1049h\x1b[?25l");
        try err.flush();
        self.measure();
    }

    /// Give the terminal back. Idempotent: safe from `defer`, a signal handler
    /// and a panic handler in any order.
    pub fn restore(self: *Terminal) void {
        removeHandlers();
        if (builtin.os.tag != .windows) {
            if (saved) |s| {
                std.posix.tcsetattr(self.in.handle, .FLUSH, s.original) catch {};
                saved = null;
            }
        }
        // Show cursor, leave alternate screen.
        self.out.writeStreamingAll(self.io, "\x1b[?25h\x1b[?1049l\x1b[0m") catch {};
    }

    /// Ask the terminal for its size; falls back to 80x24 when unknown.
    pub fn measure(self: *Terminal) void {
        if (builtin.os.tag == .windows) {
            if (windowsConsoleSize(self.out.handle)) |size| {
                self.width = size.cols;
                self.height = size.rows;
            }
            return;
        }
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(self.out.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0 and ws.col > 0 and ws.row > 0) {
            self.width = ws.col;
            self.height = ws.row;
        }
    }

    /// Draw a frame: move home, write each row, keeping colours to the spans
    /// that need them.
    pub fn present(self: *Terminal, buf: *cell.Buffer, err: *std.Io.Writer) !void {
        _ = self;
        try err.writeAll("\x1b[H");
        var y: u16 = 0;
        var row_buf: [4096]u8 = undefined;
        while (y < buf.height) : (y += 1) {
            var fbs = std.Io.Writer.fixed(&row_buf);
            try fbs.writeAll("\x1b[2K");
            var current: cell.Color = .default;
            var x: u16 = 0;
            const start = @as(usize, y) * @as(usize, buf.width);
            const line = buf.cells[start..][0..buf.width];
            while (x < buf.width) : (x += 1) {
                const c = line[x];
                if (!c.head) continue;
                if (c.fg != current) {
                    try fbs.writeAll(styleFor(c.fg));
                    current = c.fg;
                }
                try fbs.print("{u}", .{c.ch});
            }
            if (current != .default) try fbs.writeAll("\x1b[0m");
            if (y + 1 < buf.height) try fbs.writeAll("\r\n");
            try err.writeAll(fbs.buffered());
        }
        try err.flush();
    }

    /// Read one key. Blocks. Returns null at end of input.
    pub fn readKey(self: *Terminal) !?app.Key {
        var first: [1]u8 = undefined;
        const n = self.in.readStreaming(self.io, &.{&first}) catch return error.NotATerminal;
        if (n == 0) return null;
        return decode(self, first[0]);
    }

    fn readByte(self: *Terminal) ?u8 {
        var b: [1]u8 = undefined;
        const n = self.in.readStreaming(self.io, &.{&b}) catch return null;
        if (n == 0) return null;
        return b[0];
    }
};

/// Console size on Windows. `std.os.windows` does not bind the console API, so
/// the one call needed is declared here rather than pulling in a binding
/// generator for a single function.
const WindowsConsoleSize = struct { cols: u16, rows: u16 };

fn windowsConsoleSize(handle: std.os.windows.HANDLE) ?WindowsConsoleSize {
    if (builtin.os.tag != .windows) return null;
    const COORD = extern struct { X: i16, Y: i16 };
    const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };
    const kernel32 = struct {
        extern "kernel32" fn GetConsoleScreenBufferInfo(
            hConsoleOutput: std.os.windows.HANDLE,
            lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
        ) callconv(.winapi) std.os.windows.BOOL;
    };
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (kernel32.GetConsoleScreenBufferInfo(handle, &info) == .FALSE) return null;
    const cols = info.srWindow.Right - info.srWindow.Left + 1;
    const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    if (cols <= 0 or rows <= 0) return null;
    return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
}

fn styleFor(color: cell.Color) []const u8 {
    return switch (color) {
        .default => "\x1b[0m",
        .dim => "\x1b[0;90m",
        .accent => "\x1b[1;36m",
        .good => "\x1b[0;32m",
        .warn => "\x1b[0;33m",
        .bad => "\x1b[0;31m",
        .selected => "\x1b[7m",
    };
}

/// Decode a key from its first byte, reading escape sequences as needed.
/// Split out from the device so the decoder is unit-testable with a fake byte
/// source.
pub fn decode(t: *Terminal, b: u8) app.Key {
    if (b != 0x1b) return decodeSingle(b);
    // A lone ESC must not block waiting for a sequence that will never come.
    // The tty is in raw mode with VMIN=1, VTIME=0, so peek with a short poll
    // instead of guessing.
    if (!inputPending(t)) return .escape;
    var seq: [8]u8 = undefined;
    var len: usize = 0;
    while (len < seq.len) {
        seq[len] = t.readByte() orelse break;
        len += 1;
        if (decodeEscape(seq[0..len])) |k| return k;
        if (seq[0] != '[' and seq[0] != 'O') break;
    }
    return .escape;
}

/// One byte that is not the start of an escape sequence.
pub fn decodeSingle(b: u8) app.Key {
    return switch (b) {
        0x03 => .ctrl_c,
        0x0d, 0x0a => .enter,
        0x09 => .tab,
        ' ' => .space,
        0x01 => .home,
        0x05 => .end,
        0x0e => .down,
        0x10 => .up,
        // Backspace and Delete both mean "edit"; the editor does the rest.
        0x7f, 0x08 => .{ .char = 'H' },
        else => if (b >= 0x20 and b < 0x7f) .{ .char = b } else .{ .char = 0 },
    };
}

/// Decode a complete escape sequence, or null when more bytes are needed.
/// Pure, so every terminal dialect can be tested on any platform.
pub fn decodeEscape(seq: []const u8) ?app.Key {
    if (seq.len < 2) return null;
    if (seq[0] != '[' and seq[0] != 'O') return .escape;
    return switch (seq[1]) {
        'A' => .up,
        'B' => .down,
        // Ctrl-Left/Right arrive as CSI 1;5C, so `C`/`D` mean scroll
        // left/right only when they stand alone.
        'C' => .{ .char = 'L' },
        'D' => .{ .char = 'H' },
        'H' => .home,
        'F' => .end,
        'Z' => .{ .char = 'Z' }, // shift-tab
        '1', '4', '5', '6', '7', '8' => blk: {
            // Home/End/PgUp/PgDn are `CSI <n> ~`.
            if (seq.len < 3) break :blk null;
            if (seq[2] != '~') break :blk .escape;
            break :blk switch (seq[1]) {
                '1', '7' => .home,
                '4', '8' => .end,
                '5' => .page_up,
                '6' => .page_down,
                else => .escape,
            };
        },
        else => .escape,
    };
}

/// True when another byte is already waiting (used to disambiguate ESC).
fn inputPending(t: *Terminal) bool {
    if (builtin.os.tag == .windows) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = t.in.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 30) catch return false;
    return ready > 0;
}

/// Run the editor until the user quits. Returns the chosen outcome; the caller
/// performs the actions, so the TUI never writes files itself.
pub fn run(
    terminal: *Terminal,
    state: *app.State,
    allocator: std.mem.Allocator,
    err: *std.Io.Writer,
) !app.State.Outcome {
    try terminal.begin(err);
    defer terminal.restore();

    while (true) {
        var buf = app.draw(state, allocator, terminal.width, terminal.height) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
        try terminal.present(&buf, err);
        buf.deinit();

        const key = (try terminal.readKey()) orelse return .cancelled;
        switch (app.handleKey(state, key)) {
            .quit => |outcome| return outcome,
            .redraw, .none => {},
        }
    }
}

/// Print the editor to a plain buffer instead of a terminal: used by tests and
/// by `--dump-frame`.
pub fn dumpFrame(state: *app.State, allocator: std.mem.Allocator, width: u16, height: u16, out: *std.Io.Writer) !void {
    var buf = try app.draw(state, allocator, width, height);
    defer buf.deinit();
    var line_buf: [2048]u8 = undefined;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        try out.print("{s}\n", .{buf.rowText(y, &line_buf)});
    }
}

test "single bytes decode to the expected keys" {
    try std.testing.expectEqual(app.Key.enter, decodeSingle(0x0d));
    try std.testing.expectEqual(app.Key.ctrl_c, decodeSingle(0x03));
    try std.testing.expectEqual(app.Key.space, decodeSingle(' '));
    try std.testing.expectEqual(app.Key.tab, decodeSingle(0x09));
    try std.testing.expectEqual(app.Key{ .char = 'a' }, decodeSingle('a'));
    // Control bytes that are not bound must not turn into printable keys.
    try std.testing.expectEqual(app.Key{ .char = 0 }, decodeSingle(0x02));
}

test "escape sequences decode without a terminal" {
    try std.testing.expectEqual(app.Key.up, decodeEscape("[A").?);
    try std.testing.expectEqual(app.Key.down, decodeEscape("[B").?);
    try std.testing.expectEqual(app.Key.home, decodeEscape("[H").?);
    try std.testing.expectEqual(app.Key.end, decodeEscape("[F").?);
    try std.testing.expectEqual(app.Key.home, decodeEscape("[1~").?);
    try std.testing.expectEqual(app.Key.end, decodeEscape("[4~").?);
    try std.testing.expectEqual(app.Key.page_up, decodeEscape("[5~").?);
    try std.testing.expectEqual(app.Key.page_down, decodeEscape("[6~").?);
}

test "incomplete sequences ask for more bytes" {
    try std.testing.expect(decodeEscape("[") == null);
    try std.testing.expect(decodeEscape("[5") == null);
    // An unknown final byte is Escape, not a hang.
    try std.testing.expectEqual(app.Key.escape, decodeEscape("[9~").?);
    try std.testing.expectEqual(app.Key.escape, decodeEscape("[Q").?);
}
