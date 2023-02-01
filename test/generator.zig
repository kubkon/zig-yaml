
const std = @import("std");
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
    \\
;
 
pub const GenerateStep = struct {
    step: Step,
    builder: *Builder,

    output_file: std.build.GeneratedFile,

    /// Create the builder, which will generate the YAML test file for us
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


    /// Walk the 'data' dir, follow the symlinks, emit the file into the cache
    fn make(step: *Step) !void {
        const self = @fieldParentPtr(GenerateStep, "step", step);
        const cwd = std.fs.cwd();
        
        var out_buffer = std.ArrayList(u8).init(self.builder.allocator);
        
        const writer = out_buffer.writer();
        
        try writer.writeAll(preamble);
        
        
        //read the tags, follow the links, generate the tests
        const root_data_dir = path.join(self.builder.allocator, &[_][]const u8{
            self.builder.build_root,
            "test/data",
        }) catch unreachable;
         
        const tagdir = try std.fs.openDirAbsolute(root_data_dir, .{});
        
        var itdir = try tagdir.openIterableDir("tags",.{});
        
        var walker = try itdir.walk(self.builder.allocator);
        defer walker.deinit();
        loop: {
            while (walker.next()) |entry| {
                if (entry) |e| {
                    if(emitTestForTag(self.builder.allocator, writer, e.path, e)) |_| {} else |_| {}
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

    fn canAccess(file_path: []const u8) bool {
        const cwd = std.fs.cwd();
        if(cwd.access(file_path,.{})) {
            return true;
        } else |_| {
            return false;
        }
    }
    
    fn emitTestForTag(allocator: Allocator, writer: anytype, name: []const u8, dir: std.fs.IterableDir.Walker.WalkerEntry) !void {
        
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
        try cwd.access(input_file_path,.{});
        
        //we have access to the input file at the path specified,
        //we have also determined if we expect an error or not
        //we can now emit the basic test case

        try emitFunctionStart(writer, name);

        //the presence of an error file means our parser/tokeniser SHOULD get an error
        if(has_error_file) {
            try emitErrorIsSuccessCase(writer,input_file_path);
        }
        //otherwise we expect the parsing to succeed correctly
        else {
            try emitErrorIsFailureCase(writer,input_file_path); 
        }
                
        try emitFunctionFinish(writer);
        
    }

    fn emitFunctionStart(writer: anytype, name: []const u8) !void {
        try writer.writeAll("test \"");
        try writer.writeAll(name);
        try writer.writeAll("\" {\n");
    }

    fn emitFunctionFinish(writer: anytype) !void {
        try writer.writeAll("}\n\n");
    }

    fn emitErrorIsSuccessCase(writer: anytype, name: []const u8) !void {
        //Write: var yaml = loadFromFile("PATH/TO/FILE/in.yaml") catch return;
        try writer.writeAll("    var yaml = loadFromFile(\"");
        try writer.writeAll(name);
        try writer.writeAll("\") catch return;\n");
        //write rest of function
        try writer.writeAll("    defer yaml.deinit();\n");
        try writer.writeAll("    return error.UnexpectedSuccess;\n");
    }

    fn emitErrorIsFailureCase(writer: anytype, name: []const u8) !void {
        //Write: var yaml = loadFromFile("PATH/TO/FILE/in.yaml") catch return error.Failed;
        try writer.writeAll("    var yaml = loadFromFile(\"");
        try writer.writeAll(name);
        try writer.writeAll("\") catch return error.Failed;\n");
        //write rest of function
        try writer.writeAll("    defer yaml.deinit();\n");
    }
};
