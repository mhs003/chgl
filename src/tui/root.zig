//! The interactive editor: a pure core (`app`) and a terminal layer (`term`).

pub const app = @import("app.zig");
pub const cell = @import("cell.zig");
pub const term = @import("term.zig");

pub const State = app.State;
pub const View = app.View;
pub const PlanView = app.PlanView;
pub const Terminal = term.Terminal;
pub const run = term.run;
pub const dumpFrame = term.dumpFrame;
pub const isTty = term.isTty;
pub const defaultOutcome = app.defaultOutcome;
