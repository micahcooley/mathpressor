//! build.zig — Mathpressor build graph (Zig 0.14.x).
//!
//! Produces two artifacts plus a test step:
//!   * `mathpressor`      — the standalone daemon/CLI executable.
//!   * `libmathpressor.so`— the GIP shared library the Ghost Engine links to.
//!
//! Both ship stripped of debug symbols and default to ReleaseFast: this is a
//! runtime synthesis engine, so we optimize hard for the shipping build.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseFast for the prototype's "ship it" profile; overridable
    // on the command line with -Doptimize=Debug etc. We use an explicit option
    // (instead of standardOptimizeOption) so a bare `zig build` already yields
    // the optimized, stripped shipping artifacts.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast for the shipping engine)",
    ) orelse .ReleaseFast;

    // --- Standalone daemon / CLI ---------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true, // strip all debug symbols from the final binary
    });
    const exe = b.addExecutable(.{
        .name = "mathpressor",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // --- GIP shared library (C-ABI) ------------------------------------------
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/gip_interface.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    const lib = b.addLibrary(.{
        .name = "mathpressor",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    // --- `zig build run` ------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Mathpressor daemon/CLI");
    run_step.dependOn(&run_cmd.step);

    // --- `zig build test` -----------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);
}
