const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("yaml", "src/yaml.zig");
    lib.setBuildMode(mode);
    lib.install();

    var yaml_tests = b.addTest("src/yaml.zig");
    yaml_tests.setBuildMode(mode);

    var e2e_tests = b.addTest("test/test.zig");
    e2e_tests.setBuildMode(mode);
    e2e_tests.addPackagePath("yaml", "src/yaml.zig");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&yaml_tests.step);
    test_step.dependOn(&e2e_tests.step);

    const example = b.addExecutable("yaml", "examples/yaml.zig");
    example.setBuildMode(mode);
    example.addPackagePath("yaml", "src/yaml.zig");
    example.step.dependOn(b.getInstallStep());

    const path_to_yaml = b.option([]const u8, "input-yaml", "Path to input yaml file") orelse "examples/simple.yml";

    const run_example = example.run();
    run_example.addArg(path_to_yaml);
    const run_example_step = b.step("run", "Runs examples/yaml.zig");
    run_example_step.dependOn(&run_example.step);
}
