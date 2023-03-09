const std = @import("std");
const GenerateStep = @import("test/generator.zig").GenerateStep;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const enable_logging = b.option(bool, "log", "Whether to enable logging") orelse false;
    const create_only_yaml_tests = b.option([]const []const u8, "specificYAML", "generate only YAML tests matching this eg -DspecificYAML{\"comment/6HB6\",\"EW3V\"}") orelse &[_][]const u8{};

    const enable_silent_yaml = b.option(bool, "silentYAML", "all YAML tests will pass, failures will be logged cleanly") orelse false;

    const lib = b.addStaticLibrary(.{
        .name = "yaml",
        .root_source_file = .{ .path = "src/yaml.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.install();

    var yaml_tests = b.addTest(.{
        .name = "yaml",
        .kind = .@"test",
        .root_source_file = .{ .path = "src/yaml/test.zig" },
        .target = target,
        .optimize = optimize,
    });

    const example = b.addExecutable(.{
        .name = "yaml",
        .root_source_file = .{ .path = "examples/yaml.zig" },
        .target = target,
        .optimize = optimize,
    });

    var yaml_module = module(b, "./");
    example.addModule("yaml", yaml_module);
    yaml_tests.addModule("yaml", yaml_module);

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

    var test_step = b.step("test", "Run library tests");
    test_step.dependOn(&yaml_tests.step);

    var e2e_tests = b.addTest(.{
        .name = "e2e_tests",
        .kind = .@"test",
        .root_source_file = .{ .path = "test/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    e2e_tests.addModule("yaml", yaml_module);
    test_step.dependOn(&e2e_tests.step);

    const enable_macos_sdk = b.option(bool, "enable-spec-tests", "Attempt to generate and run the full yaml 1.2 test suite.") orelse false;

    if (enable_macos_sdk == false) {
        return;
    }

    const cwd = std.fs.cwd();
    if (cwd.access("test/data", .{})) {
        std.debug.print("Found 'data' directory with YAML tests. Attempting to generate test cases\n", .{});

        const gen = GenerateStep.init(b, "yamlTest.zig", create_only_yaml_tests, enable_silent_yaml);
        test_step.dependOn(&gen.step);

        var full_yaml_tests = b.addTest(.{
            .name = "full_yaml_tests",
            .kind = .@"test",
            .root_source_file = .{ .path = "zig-cache/yamlTest.zig" },
            .target = target,
            .optimize = optimize,
        });

        full_yaml_tests.addModule("yaml", yaml_module);

        test_step.dependOn(&full_yaml_tests.step);
    } else |_| {
        std.debug.print("No 'data' directory with YAML tests provided\n", .{});
    }
}

var cached_pkg: ?*std.Build.Module = null;

pub fn module(b: *std.Build, path: []const u8) *std.Build.Module {
    if (cached_pkg == null) {
        const yaml_path = std.fs.path.join(b.allocator, &[_][]const u8{ path, "src/yaml.zig" }) catch unreachable;

        const yaml_module = b.createModule(.{
            .source_file = .{ .path = yaml_path },
            .dependencies = &.{},
        });

        cached_pkg = yaml_module;
    }

    return cached_pkg.?;
}
