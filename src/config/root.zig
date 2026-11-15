//! Configuration: discovery, parsing, defaults, and `init`.
//!
//! Lookup order (first existing file wins):
//!   1. `--config <PATH>`
//!   2. `$CHGL_CONFIG`
//!   3. the platform config dir, holding `config.toml` or `config.json`
//!
//! TOML is the primary format because it is what Zig, Rust and Python projects
//! already write; JSON is accepted for people who prefer it. Both parse into
//! the same struct, so nothing downstream knows which was used.
//!
//! Every section is optional and defaulted. Unknown keys are rejected so a typo
//! (`max_commit` for `max_commits`) fails loudly instead of being ignored.

const std = @import("std");

pub const EXAMPLE_TOML =
    \\# chgl configuration.
    \\#
    \\# Every key is optional; the defaults below work for most repositories.
    \\# Docs: DOCS.md
    \\
    \\[changelog]
    \\# Changelog file. "auto" runs detection (CHANGELOG.md, CHANGES.md, …).
    \\file = "auto"
    \\# Tag prefix. "auto" infers it from existing tags (v0.1.0 vs 0.1.0).
    \\tag_prefix = "auto"
    \\# Cap on commits considered when no release tag exists.
    \\max_commits = 200
    \\# What to do with a non-empty [Unreleased] section:
    \\#   "absorb" - those entries ship in this release (default)
    \\#   "leave"  - treat [Unreleased] as a personal scratchpad
    \\unreleased = "absorb"
    \\# Subjects to skip. Glob syntax, not regex.
    \\exclude = [
    \\  # "chore(release):*",
    \\  # "Merge *",
    \\]
    \\
    \\[version]
    \\# Where the current version lives: auto | cargo | npm | pyproject | file | none
    \\source = "auto"
    \\# Used when source = "file".
    \\path = ""
    \\# auto | major | minor | patch
    \\bump = "auto"
    \\# Also rewrite that file during --commit --bump-version.
    \\write_back = false
    \\
    \\[output]
    \\commit_links = false
    \\issue_links = true
    \\
    \\[polish]
    \\# Off by default: the tool is fully offline unless you ask for this.
    \\enabled = false
    \\max_entries = 40
    \\extra_instructions = ""
    \\
    \\# Only needed for [polish]. Any OpenAI-compatible endpoint works.
    \\# [provider]
    \\# base_url = "https://api.openai.com/v1"
    \\# model = "gpt-4o-mini"
    \\# api_key_env = "OPENAI_API_KEY"
    \\# timeout_secs = 60
    \\
    \\[ui]
    \\# auto | dark | light | mono
    \\theme = "auto"
    \\
;

pub const EXAMPLE_JSON =
    \\{
    \\  "changelog": {
    \\    "file": "auto",
    \\    "tag_prefix": "auto",
    \\    "max_commits": 200,
    \\    "unreleased": "absorb",
    \\    "exclude": []
    \\  },
    \\  "version": {
    \\    "source": "auto",
    \\    "path": "",
    \\    "bump": "auto",
    \\    "write_back": false
    \\  },
    \\  "output": {
    \\    "commit_links": false,
    \\    "issue_links": true
    \\  },
    \\  "polish": {
    \\    "enabled": false,
    \\    "max_entries": 40,
    \\    "extra_instructions": ""
    \\  },
    \\  "ui": {
    \\    "theme": "auto"
    \\  }
    \\}
    \\
;

pub const UnreleasedPolicy = enum {
    absorb,
    leave,
};

pub const Config = struct {
    changelog: Changelog = .{},
    version: Version = .{},
    output: Output = .{},
    polish: Polish = .{},
    provider: ?Provider = null,
    ui: Ui = .{},

    pub const Changelog = struct {
        file: []const u8 = "auto",
        tag_prefix: []const u8 = "auto",
        max_commits: usize = 200,
        unreleased: UnreleasedPolicy = .absorb,
        exclude: []const []const u8 = &.{},
    };

    pub const Version = struct {
        source: []const u8 = "auto",
        path: []const u8 = "",
        bump: []const u8 = "auto",
        write_back: bool = false,
    };

    pub const Output = struct {
        commit_links: bool = false,
        issue_links: bool = true,
    };

    pub const Polish = struct {
        enabled: bool = false,
        max_entries: usize = 40,
        extra_instructions: []const u8 = "",
    };

    pub const Provider = struct {
        base_url: []const u8,
        model: []const u8,
        api_key: ?[]const u8 = null,
        api_key_env: ?[]const u8 = null,
        timeout_secs: u64 = 60,
    };

    /// Reserved for the editor's appearance. `mouse` was removed rather than
    /// shipped as a setting that does nothing: choosing what a key means is the
    /// only supported way to drive the editor.
    pub const Ui = struct {
        theme: []const u8 = "auto",
    };

    /// Validate semantics that parsing cannot express.
    pub fn validate(self: Config) error{Invalid}!void {
        switch (self.changelog.unreleased) {
            .absorb, .leave => {},
        }
        const bump = self.version.bump;
        if (!(std.mem.eql(u8, bump, "auto") or std.mem.eql(u8, bump, "major") or
            std.mem.eql(u8, bump, "minor") or std.mem.eql(u8, bump, "patch"))) return error.Invalid;
        const source = self.version.source;
        if (!(std.mem.eql(u8, source, "auto") or std.mem.eql(u8, source, "cargo") or
            std.mem.eql(u8, source, "npm") or std.mem.eql(u8, source, "pyproject") or
            std.mem.eql(u8, source, "file") or std.mem.eql(u8, source, "none"))) return error.Invalid;
        if (self.provider) |p| {
            if (p.base_url.len == 0 or p.model.len == 0) return error.Invalid;
        }
    }

    pub fn resolveApiKey(self: Config, getenv: *const fn (name: []const u8) ?[]const u8) ?[]const u8 {
        const p = self.provider orelse return null;
        if (p.api_key_env) |name| {
            if (getenv(name)) |v| {
                if (std.mem.trim(u8, v, " \t").len != 0) return v;
            }
        }
        if (p.api_key) |k| {
            if (std.mem.trim(u8, k, " \t").len != 0) return k;
        }
        return null;
    }
};

pub const Loaded = struct {
    config: Config,
    /// Path it came from, or null when there was no file and defaults apply.
    path: ?[]const u8,
};

pub const Error = error{
    OutOfMemory,
    Invalid,
    ParseFailed,
    NotUTF8,
    UnknownKey,
} || std.Io.Writer.Error;

/// A parsed config plus the allocator its string slices live in.
///
/// The parsers hand back slices pointing into their own arena. Returning a bare
/// `Config` would leave every `[]const u8` dangling once that arena was freed,
/// so ownership travels with the value.
pub const Parsed = struct {
    config: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Parse either format.
///
/// The extension decides the parser. There is no "try the other one" fallback:
/// a JSON body under `--file x.toml` is a mistake worth reporting, and silently
/// accepting it hides a wrong `--config` path. No fallback also means no
/// partially-consumed arena when the first attempt fails.
pub fn parseText(allocator: std.mem.Allocator, path: []const u8, text: []const u8) Error!Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const is_json = std.mem.endsWith(u8, path, ".json");
    const config = if (is_json) try tryJson(a, text) else try tryToml(a, text);
    config.validate() catch return error.Invalid;
    return .{ .config = config, .arena = arena };
}

fn tryToml(a: std.mem.Allocator, text: []const u8) Error!Config {
    // The library drops keys the target struct does not declare, which would
    // turn `max_commit` into a silent no-op. Parsing the generic table first
    // lets us reject those keys ourselves, the way the reference tool does.
    try rejectUnknownTomlKeys(a, text);

    var p = toml.Parser(Config).init(a);
    defer p.deinit();
    // Everything the config points at lives in `a`, which `Parsed` keeps alive.
    const parsed = p.parseString(text) catch |e| {
        // A value in the document did not fit the struct — an enum spelled
        // wrongly, a number out of range — which is a validation failure, not a
        // syntax error, and the message should say so.
        return switch (e) {
            error.InvalidValueType, error.InvalidEnumTag, error.InvalidCharacter, error.UnexpectedCharacter => error.Invalid,
            else => error.ParseFailed,
        };
    };
    return parsed.value;
}

const known_top_level = [_][]const u8{ "changelog", "version", "output", "polish", "provider", "ui" };

fn rejectUnknownTomlKeys(a: std.mem.Allocator, text: []const u8) Error!void {
    var p = toml.Parser(toml.Table).init(a);
    defer p.deinit();
    // The table and every string in it are owned by the parser's own arena;
    // this pass only reads them, so there is nothing to free here.
    const table = p.parseString(text) catch return error.ParseFailed;
    const root = table.value;

    var top = root.iterator();
    while (top.next()) |entry| {
        const name = entry.key_ptr.*;
        const known = for (known_top_level) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else false;
        if (!known) return error.UnknownKey;
        if (entry.value_ptr.* != .table) return error.ParseFailed;
        const nested_known = knownKeysFor(name) orelse continue;
        var nested = entry.value_ptr.table.iterator();
        while (nested.next()) |n| {
            const knob = n.key_ptr.*;
            const ok = for (nested_known) |k| {
                if (std.mem.eql(u8, k, knob)) break true;
            } else false;
            if (!ok) return error.UnknownKey;
        }
    }
}

fn knownKeysFor(section: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, section, "changelog")) return &.{ "file", "tag_prefix", "max_commits", "unreleased", "exclude" };
    if (std.mem.eql(u8, section, "version")) return &.{ "source", "path", "bump", "write_back" };
    if (std.mem.eql(u8, section, "output")) return &.{ "commit_links", "issue_links" };
    if (std.mem.eql(u8, section, "polish")) return &.{ "enabled", "max_entries", "extra_instructions" };
    if (std.mem.eql(u8, section, "provider")) return &.{ "base_url", "model", "api_key", "api_key_env", "timeout_secs" };
    if (std.mem.eql(u8, section, "ui")) return &.{"theme"};
    return null;
}

fn tryJson(a: std.mem.Allocator, text: []const u8) Error!Config {
    const parsed = std.json.parseFromSlice(Config, a, text, .{}) catch return error.ParseFailed;
    return parsed.value;
}

/// Resolve the config directory. Windows has no `$HOME` in PowerShell, so
/// `%APPDATA%` is the native answer there; Unix follows XDG.
pub const Platform = struct {
    windows: bool,
};

pub const PLATFORM = Platform{ .windows = @import("builtin").os.tag == .windows };

/// Result buffer for `configDirFrom`; the caller copies it if it must outlive
/// the next call.
pub const dir_buffer = struct {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
};

/// A getter plus its context, so the same function serves the real
/// environment and a fake one in tests.
pub const Getter = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    fn call(self: Getter, name: []const u8) ?[]const u8 {
        const v = self.get(self.ctx, name) orelse return null;
        if (std.mem.trim(u8, v, " \t").len == 0) return null;
        return v;
    }
};

pub fn configDirFrom(platform: Platform, getter: Getter) ?[]const u8 {
    const sep = if (platform.windows) "\\" else "/";
    if (platform.windows) {
        if (getter.call("APPDATA")) |appdata| {
            return std.fmt.bufPrint(&dir_buffer.buf, "{s}{s}chgl", .{ appdata, sep }) catch null;
        }
        if (getter.call("XDG_CONFIG_HOME")) |xdg| {
            return std.fmt.bufPrint(&dir_buffer.buf, "{s}{s}chgl", .{ xdg, sep }) catch null;
        }
        if (getter.call("HOME")) |home| {
            return std.fmt.bufPrint(&dir_buffer.buf, "{s}{s}.config{s}chgl", .{ home, sep, sep }) catch null;
        }
        if (getter.call("USERPROFILE")) |up| {
            return std.fmt.bufPrint(&dir_buffer.buf, "{s}{s}.config{s}chgl", .{ up, sep, sep }) catch null;
        }
        return null;
    }
    if (getter.call("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(&dir_buffer.buf, "{s}/chgl", .{xdg}) catch null;
    }
    if (getter.call("HOME")) |home| {
        return std.fmt.bufPrint(&dir_buffer.buf, "{s}/.config/chgl", .{home}) catch null;
    }
    return null;
}

/// Environment lookup backed by the process environment.
pub const EnvGetter = struct {
    map: *const std.process.Environ.Map,

    pub fn getter(self: *EnvGetter) Getter {
        return .{ .ctx = self, .get = getFn };
    }

    fn getFn(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *EnvGetter = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
    }
};

/// Getter over a fixed table, for tests.
pub const FakeEnv = struct {
    pairs: []const [2][]const u8,

    pub fn getter(self: *FakeEnv) Getter {
        return .{ .ctx = self, .get = getFn };
    }

    fn getFn(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p[0], name)) return p[1];
        }
        return null;
    }
};

test "toml parses with defaults" {
    const a = std.testing.allocator;
    var parsed = try parseText(a, "config.toml", "[changelog]\nmax_commits = 5\n");
    defer parsed.deinit();
    const cfg = parsed.config;
    try std.testing.expectEqual(@as(usize, 5), cfg.changelog.max_commits);
    try std.testing.expectEqualStrings("auto", cfg.changelog.file);
    try std.testing.expectEqual(UnreleasedPolicy.absorb, cfg.changelog.unreleased);
    try std.testing.expect(!cfg.polish.enabled);
    try std.testing.expect(cfg.provider == null);
}

test "json parses with defaults" {
    const a = std.testing.allocator;
    var parsed = try parseText(a, "config.json", "{\"changelog\":{\"file\":\"X.md\"}}");
    defer parsed.deinit();
    const cfg = parsed.config;
    try std.testing.expectEqualStrings("X.md", cfg.changelog.file);
}

test "the example config parses in both formats" {
    const a = std.testing.allocator;
    var t = try parseText(a, "config.toml", EXAMPLE_TOML);
    defer t.deinit();
    try std.testing.expectEqualStrings("auto", t.config.version.source);
    var j = try parseText(a, "config.json", EXAMPLE_JSON);
    defer j.deinit();
    try std.testing.expectEqual(@as(usize, 200), j.config.changelog.max_commits);
}

test "unknown keys are rejected" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownKey, parseText(a, "config.toml", "[changelog]\nmax_commit = 5\n"));
    try std.testing.expectError(error.UnknownKey, parseText(a, "config.toml", "[nope]\nx = 1\n"));
    try std.testing.expectError(error.ParseFailed, parseText(a, "config.json", "{\"nope\":1}"));
}

test "invalid enum values are rejected" {
    const a = std.testing.allocator;
    // A value of the wrong type or spelling is a validation failure, so the
    // message can name the key instead of blaming the syntax.
    try std.testing.expectError(error.Invalid, parseText(a, "config.toml", "[changelog]\nunreleased = \"nope\"\n"));
    try std.testing.expectError(error.Invalid, parseText(a, "config.toml", "[version]\nbump = \"sometimes\"\n"));
}

test "api key prefers the environment" {
    const cfg = Config{ .provider = .{ .base_url = "http://x", .model = "m", .api_key = "inline", .api_key_env = "KEY" } };
    const getenv = struct {
        fn f(name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "KEY")) "from-env" else null;
        }
    }.f;
    try std.testing.expectEqualStrings("from-env", cfg.resolveApiKey(getenv).?);
    const empty = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqualStrings("inline", cfg.resolveApiKey(empty).?);
}

test "config dir follows each platform" {
    const win = Platform{ .windows = true };
    const unix = Platform{ .windows = false };

    var appdata = FakeEnv{ .pairs = &.{ .{ "APPDATA", "C:\\Users\\me\\AppData\\Roaming" }, .{ "HOME", "C:\\Users\\me" } } };
    try std.testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\chgl", configDirFrom(win, appdata.getter()).?);

    var xdg = FakeEnv{ .pairs = &.{ .{ "XDG_CONFIG_HOME", "/xdg" }, .{ "HOME", "/home/a" } } };
    try std.testing.expectEqualStrings("/xdg/chgl", configDirFrom(unix, xdg.getter()).?);

    var home = FakeEnv{ .pairs = &.{.{ "HOME", "/home/a" }} };
    try std.testing.expectEqualStrings("/home/a/.config/chgl", configDirFrom(unix, home.getter()).?);

    var none = FakeEnv{ .pairs = &.{} };
    try std.testing.expect(configDirFrom(win, none.getter()) == null);
    try std.testing.expect(configDirFrom(unix, none.getter()) == null);

    // A blank variable must not produce a path rooted at the filesystem root.
    var blank = FakeEnv{ .pairs = &.{ .{ "XDG_CONFIG_HOME", "   " }, .{ "HOME", "/home/a" } } };
    try std.testing.expectEqualStrings("/home/a/.config/chgl", configDirFrom(unix, blank.getter()).?);
}

const toml = @import("toml");
