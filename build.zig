const std = @import("std");
const GenerateStep = @import("test/generator.zig").GenerateStep;

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const enable_logging = b.option(bool, "log", "Whether to enable logging") orelse false;
    const create_only_yaml_tests = b.option([]const []const u8, "specificYAML", "generate only YAML tests matching this eg -DspecificYAML{\"comment/6HB6\",\"EW3V\"}") orelse &[_][]const u8{};

    const enable_silent_yaml = b.option(bool, "silentYAML", "all YAML tests will pass, failures will be logged cleanly") orelse false;

    const lib = b.addStaticLibrary("yaml", "src/yaml.zig");
    lib.setBuildMode(mode);
    lib.install();

    var yaml_tests = b.addTest("src/yaml.zig");
    yaml_tests.setBuildMode(mode);

    const example = b.addExecutable("yaml", "examples/yaml.zig");
    example.setBuildMode(mode);
    example.addPackagePath("yaml", "src/yaml.zig");

    const example_opts = b.addOptions();
    example.addOptions("build_options", example_opts);
    example_opts.addOption(bool, "enable_logging", enable_logging);
    example_opts.addOption(bool, "enable_silent_yaml", enable_silent_yaml);
    example_opts.addOption([]const []const u8, "gen_tests_only", create_only_yaml_tests);

    example.install();

    const run_cmd = example.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run example program parser");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&yaml_tests.step);

    var e2e_tests = b.addTest("test/test.zig");
    e2e_tests.setBuildMode(mode);
    e2e_tests.addPackagePath("yaml", "src/yaml.zig");
    test_step.dependOn(&e2e_tests.step);

    const cwd = std.fs.cwd();
    if(cwd.access("test/data",.{})) {
        std.debug.print("Found 'data' directory with YAML tests. Attempting to generate test cases\n",.{});
        
        const gen = GenerateStep.init(b,"yamlTest.zig",create_only_yaml_tests,enable_silent_yaml);
        test_step.dependOn(&gen.step);
        var full_yaml_tests = b.addTest("zig-cache/yamlTest.zig");
        full_yaml_tests.addPackagePath("yaml", "src/yaml.zig");
        test_step.dependOn(&full_yaml_tests.step);
    } else |_| {
        std.debug.print("No 'data' directory with YAML tests provided\n",.{});
    }
}

