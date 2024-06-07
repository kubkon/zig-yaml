const std = @import("std");
const SpecTest = @import("test/spec.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_logging = b.option(bool, "log", "Whether to enable logging") orelse false;
    const yaml_module = b.addModule("yaml", .{
        .root_source_file = b.path("src/yaml.zig"),
    });

    const yaml_tests = b.addTest(.{
        .root_source_file = b.path("src/yaml.zig"),
        .target = target,
        .optimize = optimize,
    });

    const example = b.addExecutable(.{
        .name = "yaml",
        .root_source_file = b.path("examples/yaml.zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("yaml", yaml_module);

    const example_opts = b.addOptions();
    example.root_module.addOptions("build_options", example_opts);
    example_opts.addOption(bool, "enable_logging", enable_logging);

    b.installArtifact(example);

    const run_cmd = b.addRunArtifact(example);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run example program parser");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(yaml_tests).step);

    var e2e_tests = b.addTest(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_tests.root_module.addImport("yaml", yaml_module);
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);

    const enable_spec_tests = b.option(bool, "enable-spec-tests", "Enable YAML Test Suite") orelse false;
    if (enable_spec_tests) {
        const gen = SpecTest.create(b);
        test_step.dependOn(&gen.step);
    }

}
