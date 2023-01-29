const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const enable_logging = b.option(bool, "log", "Whether to enable logging") orelse false;

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
    if(cwd.access("data",.{})) {
        std.debug.print("Found 'data' directory with YAML tests. Attempting to generate test cases\n",.{});
        
        const gen = GenerateStep.init(b,"yamlTest.zig");
        test_step.dependOn(&gen.step);
        var full_yaml_tests = b.addTest("zig-cache/yamlTest.zig");
        full_yaml_tests.addPackagePath("yaml", "src/yaml.zig");
        test_step.dependOn(&full_yaml_tests.step);
    } else |_| {
        std.debug.print("No 'data' directory with YAML tests provided\n",.{});
    }
}
 

const path = std.fs.path;
const Builder = std.build.Builder;
const Step = std.build.Step;
const Allocator = std.mem.Allocator;

const preamble =
    \\// This file is generated from the YAML 1.2 test database.
    \\
    \\const std = @import("std");
    \\const mem = std.mem;
    \\const testing = std.testing;
    \\
    \\const Allocator = mem.Allocator;
    \\const Yaml = @import("yaml").Yaml;
    \\
    \\const gpa = testing.allocator;
    \\
    \\fn loadFromFile(file_path: []const u8) !Yaml {
    \\    const file = try std.fs.cwd().openFile(file_path, .{});
    \\    defer file.close();
    \\
    \\    const source = try file.readToEndAlloc(gpa, std.math.maxInt(u32));
    \\    defer gpa.free(source);
    \\
    \\    return Yaml.load(gpa, source);
    \\}
    \\
;
 
pub const GenerateStep = struct {
    step: Step,
    builder: *Builder,

    output_file: std.build.GeneratedFile,

    /// Initialize a Vulkan generation step, for `builder`. `spec_path` is the path to
    /// vk.xml, relative to the project root. The generated bindings will be placed at
    /// `out_path`, which is relative to the zig-cache directory.
    pub fn init(builder: *Builder, out_path: []const u8) *GenerateStep {
        const self = builder.allocator.create(GenerateStep) catch unreachable;
        const full_out_path = path.join(builder.allocator, &[_][]const u8{
            builder.build_root,
            builder.cache_root,
            out_path,
        }) catch unreachable;

        self.* = .{
            .step = Step.init(.custom, "yaml-test-generate", builder.allocator, make),
            .builder = builder,
            .output_file = .{
                .step = &self.step,
                .path = full_out_path,
            },
        };
        return self;
    }

    /// Internal build function. This reads `vk.xml`, and passes it to `generate`, which then generates
    /// the final bindings. The resulting generated bindings are not formatted, which is why an ArrayList
    /// writer is passed instead of a file writer. This is then formatted into standard formatting
    /// by parsing it and rendering with `std.zig.parse` and `std.zig.render` respectively.
    fn make(step: *Step) !void {
        const self = @fieldParentPtr(GenerateStep, "step", step);
        const cwd = std.fs.cwd();
        
        var out_buffer = std.ArrayList(u8).init(self.builder.allocator);
        
        const writer = out_buffer.writer();
        
        try writer.writeAll(preamble);
        
        
        //read the tags, follow the links, generate the tests
        const root_data_dir = path.join(self.builder.allocator, &[_][]const u8{
            self.builder.build_root,
            "data",
        }) catch unreachable;
         
        const tagdir = try std.fs.openDirAbsolute(root_data_dir, .{});
        
        var itdir = try tagdir.openIterableDir("tags",.{});
        
        var walker = try itdir.walk(self.builder.allocator);
        defer walker.deinit();
        loop: {
            while (walker.next()) |entry| {
                if (entry) |e| {
                    try emitTestForTag(self.builder.allocator, writer, e.path, e);
                } else {
                   break :loop;
                }
            } else |err| {
                std.debug.print("err: {}", .{err});
                break :loop;
            }
        }
        
        try out_buffer.append(0);
        const src = out_buffer.items[0 .. out_buffer.items.len - 1 :0];
        const dir = path.dirname(self.output_file.path.?).?;
        try cwd.makePath(dir);
        try cwd.writeFile(self.output_file.path.?, src);
    }
    
    fn emitTestForTag(allocator: Allocator, writer: anytype, name: []const u8, dir: std.fs.IterableDir.Walker.WalkerEntry) !void {
        try writer.writeAll("test \"");
        try writer.writeAll(name);
        try writer.writeAll("\" {\n");
        
        const error_file_path = path.join(allocator, &[_][]const u8{
            "data/tags",
            dir.path,
            "error",
        }) catch unreachable;
        
        const cwd = std.fs.cwd();
        var has_error_file: bool = undefined;
        if(cwd.access(error_file_path,.{})) {
            has_error_file = true;
        } else |_| {
            has_error_file = false;
        }
        
        
        const input_file_path = path.join(allocator, &[_][]const u8{
            "data/tags",
            dir.path,
            "in.yaml",
        }) catch unreachable;
        
        try writer.writeAll("if(loadFromFile(\"");
        try writer.writeAll(input_file_path);
        try writer.writeAll("\")) |yaml_const| {\n");
        try writer.writeAll("    var yaml = yaml_const;\n");
        try writer.writeAll("    yaml.deinit();\n");
        try writer.writeAll("        try testing.expect(true);\n");
        try writer.writeAll("} else |_| {\n");
        
            //check if we were expecting a problem or not
            if(has_error_file) {
                try writer.writeAll("        try testing.expect(true);\n");
            } else {
                try writer.writeAll("        try testing.expect(false);\n");
            }
        
        try writer.writeAll("}\n");
         
        
        try writer.writeAll("}\n\n");
    }
};
