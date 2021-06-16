const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("yaml", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    // main_tests.addPackagePath("e2e_tests", "test/test.zig");

    var e2e_tests = b.addTest("test/test.zig");
    e2e_tests.setBuildMode(mode);
    e2e_tests.addPackagePath("yaml", "src/main.zig");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&e2e_tests.step);

    const example = b.addExecutable("yaml", "examples/yaml.zig");
    example.setBuildMode(mode);
    example.addPackagePath("yaml", "src/main.zig");
    example.step.dependOn(b.getInstallStep());

    const path_to_yaml = b.option([]const u8, "input-yaml", "Path to input yaml file") orelse "examples/simple.yml";

    const run_example = example.run();
    run_example.addArg(path_to_yaml);
    const run_example_step = b.step("run", "Runs examples/yaml.zig");
    run_example_step.dependOn(&run_example.step);
}
