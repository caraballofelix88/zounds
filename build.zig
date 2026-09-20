const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const example_name = b.option(
        []const u8,
        "example_name",
        "Name of example executable",
    ) orelse "tada";

    var exe_path_buf: [128]u8 = undefined;
    const exe_path = std.fmt.bufPrint(&exe_path_buf, "examples/{s}.zig", .{example_name}) catch "examples/tada.zig";

    const mod = b.addModule("zounds", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPlatformFrameworks(target, mod);

    //
    // Lib
    //
    const lib = b.addLibrary(.{
        .name = "zounds",
        .root_module = mod,
    });

    const lib_install = b.addInstallArtifact(lib, .{});
    lib_install.step.dependOn(b.getInstallStep());

    //
    // Example exe
    //
    const exe_mod = b.addModule(exe_path, .{
        .root_source_file = b.path(exe_path),
        .imports = &.{.{ .name = "zounds", .module = mod }},
        .target = target,
        .optimize = optimize,
    });
    // linkPlatformFrameworks(target, exe_mod);

    const exe = b.addExecutable(.{
        .name = example_name,
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    //
    // Check executable build
    //
    // const check_exe = b.addExecutable(.{
    //     .name = example_name,
    //     .root_module = exe_mod,
    // });

    //
    // Test executable
    //
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPlatformFrameworks(target, test_mod);

    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    //
    // Compile Steps
    //

    // default zig build behavior
    // lib_install.step.dependOn(b.getInstallStep());
    run_exe.step.dependOn(b.getInstallStep());

    // const lib_step = b.step("lib", "build static lib");
    // lib_step.dependOn(&lib_install.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const run_step = b.step("run", "run example");
    run_step.dependOn(&run_exe.step);

    // const check_step = b.step("check", "compile without emitting for diagnostics");
    // check_step.dependOn(&check_exe.step);
}

pub fn linkPlatformFrameworks(target: std.Build.ResolvedTarget, mod: *std.Build.Module) void {
    switch (target.result.os.tag) {
        .ios, .macos => {
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("CoreMidi", .{});
        },
        else => {},
    }
}
