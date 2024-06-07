const std = @import("std");
const Step = std.Build.Step;
const fs = std.fs;
const mem = std.mem;

const Aegis128LMac_128 = std.crypto.auth.aegis.Aegis128LMac_128;

const SpecTest = @This();

pub const base_id: Step.Id = .custom;

step: Step,
output_file: std.Build.GeneratedFile,

pub const Options = struct {
    module_name: []const u8,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

const preamble =
    \\// This file is generated from the YAML 1.2 test database.
    \\
    \\const std = @import("std");
    \\const testing = std.testing;
    \\
    \\const Yaml = @import("yaml").Yaml;
    \\
    \\const alloc = testing.allocator;
    \\
    \\fn loadFromFile(file_path: []const u8) !Yaml {
    \\    const file = try std.fs.cwd().openFile(file_path, .{});
    \\    defer file.close();
    \\
    \\    const source = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
    \\    defer alloc.free(source);
    \\
    \\    return Yaml.load(alloc, source);
    \\}
    \\
    \\
;

pub fn create(owner: *std.Build) *SpecTest {
    const spec_test = owner.allocator.create(SpecTest) catch @panic("OOM");

    spec_test.* = .{
        .step = Step.init(.{ .id = base_id, .name = "yaml-test-generate", .owner = owner, .makeFn = make }),
        .output_file = std.Build.GeneratedFile{ .step = &spec_test.step },
    };
    return spec_test;
}

fn make(step: *Step, prog_node: std.Progress.Node) !void {
    _ = prog_node;

    const spec_test: *SpecTest = @fieldParentPtr("step", step);
    const b = step.owner;

    const cwd = std.fs.cwd();
    cwd.access("test/yaml-test-suite/tags", .{}) catch {
        return spec_test.step.fail("Testfiles not found, make sure you have loaded the submodule.", .{});
    };
    if (b.host.result.os.tag == .windows) {
        return spec_test.step.fail("Windows does not support symlinks in git properly, can't run testsuite.", .{});
    }

    var output = std.ArrayList(u8).init(b.allocator);
    const writer = output.writer();

    try writer.writeAll(preamble);

    const root_data_path = fs.path.join(b.allocator, &[_][]const u8{
        b.build_root.path.?,
        "test/yaml-test-suite",
    }) catch unreachable;

    const root_data_dir = try std.fs.openDirAbsolute(root_data_path, .{});

    var itdir = try root_data_dir.openDir("tags", .{ .iterate = true, .access_sub_paths = true });

    //we now want to walk the directory, including the symlinked folders, there should be no loops
    //unsure how the walker might handle loops..
    var walker = try itdir.walk(b.allocator);
    defer walker.deinit();
    loop: {
        while (walker.next()) |entry| {
            if (entry) |e| {
                if (emitTest(b.allocator, &output, e)) |_| {} else |_| {}
            } else {
                break :loop;
            }
        } else |err| {
            std.debug.print("err: {}", .{err});
            break :loop;
        }
    }

    const key = mem.zeroes([Aegis128LMac_128.key_length]u8);
    var mac = Aegis128LMac_128.init(&key);
    mac.update(output.items);
    var bin_digest: [Aegis128LMac_128.mac_length]u8 = undefined;
    mac.final(&bin_digest);
    var filename: [Aegis128LMac_128.mac_length * 2 + 4]u8 = undefined;
    _ = std.fmt.bufPrint(&filename, "{s}.zig", .{std.fmt.fmtSliceHexLower(&bin_digest)}) catch unreachable;

    const sub_path = b.pathJoin(&.{ "yaml-test-suite", &filename });
    const sub_path_dirname = fs.path.dirname(sub_path).?;

    b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
        return step.fail("unable to make path '{}{s}': {}", .{ b.cache_root, sub_path_dirname, err });
    };

    b.cache_root.handle.writeFile(.{ .sub_path = sub_path, .data = output.items }) catch |err| {
        return step.fail("unable to write file: {}", .{err});
    };
    spec_test.output_file.path = try b.cache_root.join(b.allocator, &.{sub_path});
}

fn emitTest(alloc: mem.Allocator, output: *std.ArrayList(u8), entry: fs.Dir.Walker.Entry) !void {
    std.debug.print("{s}\n", .{entry.path});
    if (entry.kind == .sym_link) {
        // const real_path = try entry.dir.realpathAlloc(alloc, entry.basename);
        const name_file_path = fs.path.join(alloc, &[_][]const u8{
            entry.basename,
            "===",
        }) catch unreachable;
        const name_file = entry.dir.openFile(name_file_path, .{}) catch unreachable;
        defer name_file.close();
        const name = try name_file.readToEndAlloc(alloc, std.math.maxInt(u32));
        defer alloc.free(name);

        const in_file_path = fs.path.join(alloc, &[_][]const u8{
            entry.path,
            "in.yaml",
        }) catch unreachable;

        const data = std.fmt.allocPrint(alloc, "test \"{s} - {}\" {{\n    const yaml = try loadFromFile(\"{s}\");\n    defer yaml.deinit();\n}}\n\n", .{ entry.path, std.zig.fmtEscapes(name[0 .. name.len - 1]), in_file_path }) catch unreachable;
        defer alloc.free(data);
        try output.appendSlice(data);
    }
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
