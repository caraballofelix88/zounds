const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zounds", .{ .root_source_file = .{ .path = "src/main.zig" } });

    const exe = b.addExecutable(.{
        .name = "ex",
        .root_source_file = .{ .path = "examples/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zounds", mod);

    linkPlatformFrameworks(target, exe);

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

    linkPlatformFrameworks(target, main_tests);

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
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
