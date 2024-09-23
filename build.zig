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

    const mod = b.addModule("zounds", .{ .root_source_file = .{
        .src_path = .{ .owner = b, .sub_path = "src/main.zig" },
    } });

    //
    // Lib
    //
    const lib = b.addStaticLibrary(.{
        .name = "zounds",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } },
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("zounds", mod);
    linkPlatformFrameworks(target, lib);

    const lib_install = b.addInstallArtifact(lib, .{});
    lib_install.step.dependOn(b.getInstallStep());

    //
    // Example exe
    //
    const exe = b.addExecutable(.{
        .name = example_name,
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = exe_path } },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zounds", mod);
    linkPlatformFrameworks(target, exe);

    const install_exe = b.addInstallArtifact(exe, .{});
    const run_exe = b.addRunArtifact(exe);

    run_exe.step.dependOn(&install_exe.step);

    //
    // Check executable build
    //
    const check_exe = b.addExecutable(.{
        .name = example_name,
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = exe_path } },
        .target = target,
        .optimize = optimize,
    });
    check_exe.root_module.addImport("zounds", mod);
    linkPlatformFrameworks(target, check_exe);

    //
    // Test executable
    //
    const main_tests = b.addTest(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/tests.zig" } },
        .target = target,
        .optimize = optimize,
    });

    main_tests.root_module.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } });
    linkPlatformFrameworks(target, main_tests);

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

    const check_step = b.step("check", "compile without emitting for diagnostics");
    check_step.dependOn(&check_exe.step);
}

pub fn linkPlatformFrameworks(target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile) void {
    switch (target.result.os.tag) {
        .ios, .macos => {
            step.linkFramework("CoreFoundation");
            step.linkFramework("CoreAudio");
            step.linkFramework("AudioToolbox");
            step.linkFramework("CoreMidi");
        },
        else => {},
    }
}
