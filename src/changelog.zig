//! The changelog model: parsing, placing, editing.
//!
//! `parse` never edits; `edit` returns new bytes and never writes them. Whoever
//! calls `edit` decides whether the result reaches disk, which is what lets the
//! TUI preview the exact bytes a write would produce.

pub const parse = @import("changelog/parse.zig");
pub const edit = @import("changelog/edit.zig");

pub const Document = parse.Document;
pub const Placement = edit.Placement;
pub const InsertOptions = edit.InsertOptions;
