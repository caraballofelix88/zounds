const std = @import("std");

const zgui = @import("zgui");

// Needed for glfw/wgpu rendering backend
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zpool = @import("zpool");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zounds", .{ .root_source_file = .{ .path = "src/main.zig" } });

    const exe = b.addExecutable(.{
        .name = "ex",
        .root_source_file = .{ .path = "example/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zounds", mod);

    const zgui_pkg = zgui.package(b, target, optimize, .{
        .options = .{ .backend = .glfw_wgpu },
    });

    zgui_pkg.link(exe);

    // Needed for glfw/wgpu rendering backend
    const zglfw_pkg = zglfw.package(b, target, optimize, .{});
    const zpool_pkg = zpool.package(b, target, optimize, .{});
    const zgpu_pkg = zgpu.package(b, target, optimize, .{
        .deps = .{ .zpool = zpool_pkg, .zglfw = zglfw_pkg },
    });

    zglfw_pkg.link(exe);
    zgpu_pkg.link(exe);

    link(target, exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "run example");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    main_tests.root_module.addIncludePath(.{ .path = "src/main.zig" });

    link(target, main_tests);

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

pub fn link(target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile) void {
    switch (target.result.os.tag) {
        .ios, .macos => {
            // Add Coreaudio, if building for MacOS
            step.linkFramework("CoreFoundation");
            step.linkFramework("CoreAudio");
            step.linkFramework("AudioToolbox");
        },
        else => {},
    }
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
