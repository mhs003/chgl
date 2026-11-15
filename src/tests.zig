//! Test root: importing a module here is what makes its `test` blocks run.

test {
    _ = @import("errors.zig");
    _ = @import("util/glob.zig");
    _ = @import("version/semver.zig");
    _ = @import("version/source.zig");
    _ = @import("git/root.zig");
    _ = @import("git/commit.zig");
    _ = @import("git/log.zig");
    _ = @import("git/tags.zig");
    _ = @import("git/worktree.zig");
    _ = @import("cli/root.zig");
    _ = @import("changelog/parse.zig");
    _ = @import("changelog/edit.zig");
    _ = @import("detect.zig");
    _ = @import("release/entry.zig");
    _ = @import("render.zig");
    _ = @import("config/root.zig");
    _ = @import("plan.zig");
    _ = @import("meta.zig");
    _ = @import("tui/cell.zig");
    _ = @import("tui/app.zig");
    _ = @import("tui/term.zig");
}
