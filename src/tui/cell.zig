//! A tiny cell buffer.
//!
//! The interactive editor renders into one of these instead of writing escape
//! codes directly. That keeps layout a pure function of (state, size), which is
//! what makes the interface testable without a terminal: build a buffer at
//! 60x16 and assert on the text.

const std = @import("std");

pub const Color = enum(u8) {
    default,
    dim,
    accent,
    good,
    warn,
    bad,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = .default,
    /// The selected row's background. `present` draws it and forces the fg to
    /// black, so the bar is green for `Keep` and white for `Skip`.
    bg: ?Color = null,
    /// False for the continuation column of a wide character.
    head: bool = true,
};

pub const Buffer = struct {
    width: u16,
    height: u16,
    cells: []Cell,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const cells = try allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
        for (cells) |*c| c.* = .{};
        return .{ .width = width, .height = height, .cells = cells, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
    }

    pub fn clear(self: *Buffer) void {
        for (self.cells) |*c| c.* = .{};
    }

    fn row(self: *Buffer, y: u16) []Cell {
        const start = @as(usize, y) * @as(usize, self.width);
        return self.cells[start..][0..self.width];
    }

    /// Write `text` at (x, y), never past the right edge. Returns the column
    /// after the last cell written.
    pub fn put(self: *Buffer, x: u16, y: u16, text: []const u8, fg: Color) u16 {
        if (y >= self.height) return x;
        const line = self.row(y);
        var col = x;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            const w = codepointWidth(cp);
            if (w == 0) continue;
            if (col + w > self.width) break;
            // The bar is one column of the row, not the text that lands on it:
            // the selftest draws a row before marking it, and drawing must
            // never silently erase what the user is looking at.
            const bar = line[col].bg;
            line[col] = .{ .ch = cp, .fg = fg, .bg = bar };
            if (w == 2 and col + 1 < self.width) line[col + 1] = .{ .ch = ' ', .fg = fg, .head = false, .bg = bar };
            col += w;
        }
        return col;
    }

    /// Mark (x, y)..(x+len, y) as the selected row, with `color` behind it.
    /// Wide characters are marked through their continuation cell, so the bar
    /// has no holes in it.
    pub fn highlight(self: *Buffer, x: u16, y: u16, len: u16, color: Color) void {
        if (y >= self.height) return;
        const line = self.row(y);
        var i = x;
        while (i < @min(x + len, self.width)) : (i += 1) {
            line[i].bg = color;
        }
    }

    /// One row as text, right-trimmed. For tests and for copying to the frame.
    pub fn rowText(self: *Buffer, y: u16, buf: []u8) []const u8 {
        const line = self.row(y);
        var out_len: usize = 0;
        var fbs = std.Io.Writer.fixed(buf);
        for (line) |c| {
            if (!c.head) continue;
            fbs.print("{u}", .{c.ch}) catch break;
        }
        out_len = fbs.end;
        const text = fbs.buffered();
        const trimmed = std.mem.trimEnd(u8, text[0..out_len], " ");
        return trimmed;
    }
};

/// Columns a codepoint occupies. Deliberately approximate beyond width 1:
/// combining marks are skipped, the common East Asian wide ranges take 2, and
/// emoji sequences are treated as width 2 per codepoint (documented).
pub fn codepointWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    // Combining marks and zero-width joiners/selectors.
    if (cp >= 0x0300 and cp <= 0x036F) return 0;
    if (cp >= 0x200B and cp <= 0x200F) return 0;
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;
    if (cp == 0xFEFF) return 0;
    if (cp >= 0x1F300 and cp <= 0x1FAFF) return 2;
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2E80 and cp <= 0xA4CF) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x20000 and cp <= 0x3FFFD) return 2;
    return 1;
}

test "a buffer is blank and sized" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 10, 3);
    defer b.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", b.rowText(0, &buf));
}

test "text is clipped at the right edge" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 5, 1);
    defer b.deinit();
    _ = b.put(0, 0, "abcdefgh", .default);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abcde", b.rowText(0, &buf));
}

test "writing past the bottom is dropped, not a crash" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 5, 2);
    defer b.deinit();
    _ = b.put(0, 9, "nope", .default);
}

test "wide characters take two cells" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 6, 1);
    defer b.deinit();
    const end = b.put(0, 0, "日本語", .default);
    try std.testing.expectEqual(@as(u16, 6), end);
    try std.testing.expect(!b.cells[1].head);
}

test "combining marks occupy no cell" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 6, 1);
    defer b.deinit();
    const end = b.put(0, 0, "e\u{0301}x", .default);
    try std.testing.expectEqual(@as(u16, 2), end);
}

test "highlight marks the requested cells only" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 6, 1);
    defer b.deinit();
    _ = b.put(0, 0, "hello", .good);
    b.highlight(1, 0, 2, .good);
    try std.testing.expectEqual(@as(?Color, null), b.cells[0].bg);
    try std.testing.expectEqual(@as(?Color, .good), b.cells[1].bg);
    try std.testing.expectEqual(@as(?Color, .good), b.cells[2].bg);
    try std.testing.expectEqual(@as(?Color, null), b.cells[3].bg);
    // The bar is the background: the text keeps its own colour.
    try std.testing.expectEqual(Color.good, b.cells[1].fg);
}

test "writing under the bar keeps the bar" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 6, 1);
    defer b.deinit();
    b.highlight(0, 0, 6, .default);
    _ = b.put(0, 0, "ab", .warn);
    try std.testing.expectEqual(@as(?Color, .default), b.cells[0].bg);
    try std.testing.expectEqual(@as(?Color, .default), b.cells[1].bg);
    try std.testing.expectEqual(Color.warn, b.cells[0].fg);
}

test "wide characters do not punch a hole in the bar" {
    const a = std.testing.allocator;
    var b = try Buffer.init(a, 6, 1);
    defer b.deinit();
    b.highlight(0, 0, 6, .good);
    _ = b.put(0, 0, "日本", .default);
    try std.testing.expectEqual(@as(?Color, .good), b.cells[0].bg);
    try std.testing.expect(!b.cells[1].head);
    try std.testing.expectEqual(@as(?Color, .good), b.cells[1].bg);
    try std.testing.expectEqual(@as(?Color, .good), b.cells[3].bg);
}
