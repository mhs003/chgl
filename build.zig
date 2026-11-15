const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });

    // `VERSION` is embedded verbatim, so the binary and the release tooling
    // read the same file and cannot disagree.
    const version_file = b.createModule(.{ .root_source_file = b.path("VERSION"), .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "toml", .module = toml.module("toml") },
        .{ .name = "VERSION", .module = version_file },
    };

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

    const exe = b.addExecutable(.{
        .name = "chgl",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run chgl").dependOn(&run_cmd.step);

    // One test binary for the whole tree. Every module is reachable from
    // `src/tests.zig`, which is what pulls the `test` blocks in.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src", "tests" }, .check = b.option(bool, "check-fmt", "fail when files are not formatted") orelse false });
    b.step("fmt", "Check formatting").dependOn(&fmt.step);
}
