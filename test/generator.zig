const std = @import("std");
const path = std.fs.path;
const Builder = std.Build;
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
    \\
;

pub const GenerateStep = struct {
    step: Step,
    builder: *Builder,
    build_for_only: []const []const u8,
    silent_mode: bool,

    output_file: std.build.GeneratedFile,

    /// Create the builder, which will generate the YAML test file for us
    pub fn init(builder: *Builder, out_path: []const u8, build_only: []const []const u8, silent_mode: bool) *GenerateStep {
        const self = builder.allocator.create(GenerateStep) catch unreachable;
        const full_out_path = path.join(builder.allocator, &[_][]const u8{
            builder.cache_root.path.?,
            out_path,
        }) catch unreachable;

        self.* = .{
            .step = Step.init(.custom, "yaml-test-generate", builder.allocator, make),
            .builder = builder,
            .build_for_only = build_only,
            .silent_mode = silent_mode,
            .output_file = .{
                .step = &self.step,
                .path = full_out_path,
            },
        };
        return self;
    }

    /// Walk the 'data' dir, follow the symlinks, emit the file into the cache
    fn make(step: *Step) !void {
        const self = @fieldParentPtr(GenerateStep, "step", step);
        const cwd = std.fs.cwd();

        var out_buffer = std.ArrayList(u8).init(self.builder.allocator);
        const writer = out_buffer.writer();

        try writer.writeAll(preamble);

        //read the tags, follow the links, generate the tests
        const root_data_dir = path.join(self.builder.allocator, &[_][]const u8{
            self.builder.build_root.path.?,
            "test/data",
        }) catch unreachable;

        //open the root directory, which 'should' contain the tags folder.
        const tagdir = try std.fs.openDirAbsolute(root_data_dir, .{});

        //then open the tags subdirectory for iterating
        var itdir = try tagdir.openIterableDir("tags", .{});

        //we now want to walk the directory, including the symlinked folders, there should be no loops
        //unsure how the walker might handle loops..
        var walker = try itdir.walk(self.builder.allocator);
        defer walker.deinit();
        loop: {
            while (walker.next()) |entry| {
                if (entry) |e| {
                    //check if we are omitting tests.
                    var emit_tests: bool = true;
                    //if we have specified some items in the 'build for only' array
                    if (self.build_for_only.len > 0) {
                        emit_tests = false;
                        //then we need to iterate them
                        for (self.build_for_only) |permitted_test| {
                            //check if we can needle/haystack without crashing
                            //std probably needs this check and should return false if the preconditions are not met?
                            //maybe this is done already in a wrapper function
                            if (e.path.len >= permitted_test.len) {
                                //check if we have a match and should emit
                                const index = std.mem.indexOfPosLinear(u8, e.path, 0, permitted_test);
                                if (index != null) {
                                    emit_tests = true;
                                }
                            }
                        }
                    }

                    //for any valid entry, we can emit a test,
                    if (emit_tests) {
                        if (emitTestForTag(self.builder.allocator, writer, e.path, e, self.silent_mode)) |_| {} else |_| {}
                    }
                } else {
                    break :loop;
                }
            } else |err| {
                std.debug.print("err: {}", .{err});
                break :loop;
            }
        }

        //our buffer now has all the tests, we can dump it out to the file
        try out_buffer.append(0);
        const src = out_buffer.items[0 .. out_buffer.items.len - 1 :0];
        const dir = path.dirname(self.output_file.path.?).?;
        try cwd.makePath(dir);
        try cwd.writeFile(self.output_file.path.?, src);
    }

    //access returns an error or is void, this will make it a bool
    //behaviour of some of the tests is determined by the presence (as opposed to contents) of a file
    fn canAccess(file_path: []const u8) bool {
        const cwd = std.fs.cwd();
        if (cwd.access(file_path, .{})) {
            return true;
        } else |_| {
            return false;
        }
    }

    fn emitTestForTag(allocator: Allocator, writer: anytype, name: []const u8, dir: std.fs.IterableDir.Walker.WalkerEntry, silent: bool) !void {
        const error_file_path = path.join(allocator, &[_][]const u8{
            "test/data/tags",
            dir.path,
            "error",
        }) catch unreachable;

        const has_error_file: bool = canAccess(error_file_path);

        const input_file_path = path.join(allocator, &[_][]const u8{
            "test/data/tags",
            dir.path,
            "in.yaml",
        }) catch unreachable;

        //if we cannot acces the input file here, we may as well bail
        //possibly the directory structure changed, submit bug report?
        const cwd = std.fs.cwd();
        try cwd.access(input_file_path, .{});

        //load the header file that contains test information
        const header_file_path = path.join(allocator, &[_][]const u8{ "test/data/tags", dir.path, "===" }) catch unreachable;

        const file = try std.fs.cwd().openFile(header_file_path, .{});
        defer file.close();
        const header_source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
        defer allocator.free(header_source);

        //we have access to the input file at the path specified,
        //we have also determined if we expect an error or not
        //we can now emit the basic test case

        try emitFunctionStart(writer, name, header_source);

        //it means silent for Zig test. so the test will always pass, but we will log the information
        //about the actual success or failure of the test, so we can determine what we need to do
        //to get compliance.
        if (silent) {
            try emitDetailed(writer, input_file_path, has_error_file);
        } else {

            //the presence of an error file means our parser/tokeniser SHOULD get an error
            if (has_error_file) {
                try emitErrorIsSuccessCase(writer, input_file_path);
            }
            //otherwise we expect the parsing to succeed correctly
            else {
                try emitErrorIsFailureCase(writer, input_file_path);
            }
        }

        try emitFunctionFinish(writer);
    }

    //constant text for the detailed load success/fail cases

    const verbose_loadfile =
        \\    var failed: bool = false;
        \\    if(loadFromFile("
    ;
    const verbose_expect_error =
        \\")) |it_parsed| {
        \\        var yml = it_parsed;
        \\        yml.deinit();
        \\        failed = true;
        \\    } else |_| {
        \\        std.debug.print("success\n",.{});
        \\    }
        \\
        \\    if(failed) {
        \\      return error.Failed;
        \\    }
    ;

    const verbose_expect_no_error =
        \\")) |it_parsed| {
        \\       var yml = it_parsed;
        \\       yml.deinit();
        \\       std.debug.print("success\n",.{});
        \\    } else |_| {
        \\        failed = true;
        \\    }
        \\    if(failed) {
        \\      return error.Failed;
        \\    }
    ;

    fn emitDetailed(writer: anytype, name: []const u8, has_error: bool) !void {
        try writer.writeAll(verbose_loadfile);
        try writer.writeAll(name);
        if (has_error) {
            try writer.writeAll(verbose_expect_error);
        } else {
            try writer.writeAll(verbose_expect_no_error);
        }
    }

    //constant text for the standard load success/fail cases

    const loadfile =
        \\    var yaml = loadFromFile("
    ;

    const endErrorSuccess =
        \\") catch return;
        \\    defer yaml.deinit();
        \\    return error.UnexpectedSuccess;
        \\
    ;

    const endErrorIsFailure =
        \\") catch return error.Failed;
        \\    defer yaml.deinit();
        \\
    ;

    fn emitErrorIsSuccessCase(writer: anytype, name: []const u8) !void {
        try writer.writeAll(loadfile);
        try writer.writeAll(name);
        try writer.writeAll(endErrorSuccess);
    }

    fn emitErrorIsFailureCase(writer: anytype, name: []const u8) !void {
        try writer.writeAll(loadfile);
        try writer.writeAll(name);
        try writer.writeAll(endErrorIsFailure);
    }

    //function start and finish
    fn emitFunctionStart(writer: anytype, name: []const u8, details: []const u8) !void {
        try writer.writeAll("//");
        try writer.writeAll(details);
        try writer.writeAll("\n");
        try writer.writeAll("test \"");
        try writer.writeAll(name);
        try writer.writeAll("\" {\n");
    }

    fn emitFunctionFinish(writer: anytype) !void {
        try writer.writeAll("}\n\n\n");
    }
};
