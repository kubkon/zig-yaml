const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const Allocator = mem.Allocator;
const Step = std.Build.Step;
const SpecTest = @This();

pub const base_id: Step.Id = .custom;

step: Step,
output_file: std.Build.GeneratedFile,

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
    \\    const file = try std.fs.openFileAbsolute(file_path, .{});
    \\    defer file.close();
    \\
    \\    const source = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
    \\    defer alloc.free(source);
    \\
    \\    return Yaml.load(alloc, source);
    \\}
    \\
    \\fn loadFileString(file_path: []const u8) ![]u8 {
    \\    const file = try std.fs.openFileAbsolute(file_path, .{});
    \\    defer file.close();
    \\
    \\    const source = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
    \\    return source;
    \\}
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

pub fn path(spec_test: *SpecTest) std.Build.LazyPath {
    return std.Build.LazyPath{ .generated = .{ .file = &spec_test.output_file } };
}

const Testcase = struct {
    name: []const u8,
    path: []const u8,
    result: union(enum) {
        expected_output_path: []const u8,
        error_expected,
        none,
    },
    tags: std.BufSet,
};

fn make(step: *Step, make_options: Step.MakeOptions) !void {
    _ = make_options;

    const spec_test: *SpecTest = @fieldParentPtr("step", step);
    const b = step.owner;

    const cwd = std.fs.cwd();
    cwd.access("test/yaml-test-suite/tags", .{}) catch {
        return spec_test.step.fail("Testfiles not found, make sure you have loaded the submodule.", .{});
    };
    if (b.graph.host.result.os.tag == .windows) {
        return spec_test.step.fail("Windows does not support symlinks in git properly, can't run testsuite.", .{});
    }

    var arena_allocator = std.heap.ArenaAllocator.init(b.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var testcases = std.StringArrayHashMap(Testcase).init(arena);

    const root_data_path = fs.path.join(arena, &[_][]const u8{
        b.build_root.path.?,
        "test/yaml-test-suite",
    }) catch unreachable;

    const root_data_dir = try std.fs.openDirAbsolute(root_data_path, .{});

    var itdir = try root_data_dir.openDir("tags", .{
        .iterate = true,
        .access_sub_paths = true,
    });

    var walker = try itdir.walk(arena);
    defer walker.deinit();

    loop: {
        while (walker.next()) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (entry.kind != .sym_link) continue;
                collectTest(arena, entry, &testcases) catch |err| switch (err) {
                    error.OutOfMemory => @panic("OOM"),
                    else => @panic("unexpected error occurred while collecting tests"),
                };
            } else {
                break :loop;
            }
        } else |err| {
            std.debug.print("err: {}", .{err});
            break :loop;
        }
    }

    var output = std.ArrayList(u8).init(arena);
    const writer = output.writer();
    try writer.writeAll(preamble);

    while (testcases.popOrNull()) |kv| {
        try emitTest(arena, &output, kv.value);
    }

    var man = b.graph.cache.obtain();
    defer man.deinit();

    man.hash.addBytes(output.items);

    if (try step.cacheHit(&man)) {
        const digest = man.final();
        spec_test.output_file.path = try b.cache_root.join(arena, &.{
            "yaml-test-suite", &digest,
        });
        return;
    }
    const digest = man.final();

    const sub_path = b.pathJoin(&.{ "yaml-test-suite", &digest });
    const sub_path_dirname = fs.path.dirname(sub_path).?;

    b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
        return step.fail("unable to make path '{}{s}': {}", .{ b.cache_root, sub_path_dirname, err });
    };

    b.cache_root.handle.writeFile(.{ .sub_path = sub_path, .data = output.items }) catch |err| {
        return step.fail("unable to write file: {}", .{err});
    };
    spec_test.output_file.path = try b.cache_root.join(arena, &.{sub_path});
    try man.writeManifest();
}

fn collectTest(arena: Allocator, entry: fs.Dir.Walker.Entry, testcases: *std.StringArrayHashMap(Testcase)) !void {
    var path_components_it = try std.fs.path.componentIterator(entry.path);
    const first_path = path_components_it.first().?;

    var path_components = std.ArrayList([]const u8).init(arena);
    while (path_components_it.next()) |component| {
        try path_components.append(component.name);
    }

    const remaining_path = try fs.path.join(arena, path_components.items);
    const result = try testcases.getOrPut(remaining_path);

    if (!result.found_existing) {
        result.key_ptr.* = remaining_path;

        const in_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "in.yaml",
        });
        const real_in_path = try entry.dir.realpathAlloc(arena, in_path);

        const name_file_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "===",
        });
        const name_file = try entry.dir.openFile(name_file_path, .{});
        defer name_file.close();
        const name = try name_file.readToEndAlloc(arena, std.math.maxInt(u32));

        var tag_set = std.BufSet.init(arena);
        try tag_set.insert(first_path.name);

        const full_name = try std.fmt.allocPrint(arena, "{s} - {s}", .{
            remaining_path,
            name[0 .. name.len - 1],
        });

        result.value_ptr.* = .{
            .name = full_name,
            .path = real_in_path,
            .result = .{ .none = {} },
            .tags = tag_set,
        };

        const out_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "out.yaml",
        });
        const err_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "error",
        });

        if (canAccess(entry.dir, out_path)) {
            const real_out_path = try entry.dir.realpathAlloc(arena, out_path);
            result.value_ptr.result = .{ .expected_output_path = real_out_path };
        } else if (canAccess(entry.dir, err_path)) {
            result.value_ptr.result = .{ .error_expected = {} };
        }
    } else {
        try result.value_ptr.tags.insert(first_path.name);
    }
}

const no_output_template =
    \\    var yaml = try loadFromFile("{s}");
    \\    defer yaml.deinit();
    \\
;

const expect_file_template =
    \\    var yaml = try loadFromFile("{s}");
    \\    defer yaml.deinit();
    \\
    \\    const expected = try loadFileString("{s}");
    \\    defer alloc.free(expected);
    \\
    \\    var buf = std.ArrayList(u8).init(alloc);
    \\    defer buf.deinit();
    \\    try yaml.stringify(&buf.writer());
    \\    const actual = try buf.toOwnedSlice();
    \\    try testing.expect(std.meta.eql(expected, actual));
    \\
;

const expect_err_template =
    \\    var yaml = loadFromFile("{s}") catch return;
    \\    defer yaml.deinit();
    \\    return error.UnexpectedSuccess;
    \\
;

fn emitTest(arena: Allocator, output: *std.ArrayList(u8), testcase: Testcase) !void {
    const head = std.fmt.allocPrint(arena, "test \"{}\" {{\n", .{
        std.zig.fmtEscapes(testcase.name),
    }) catch @panic("OOM");
    try output.appendSlice(head);

    switch (testcase.result) {
        .none => {
            const body = std.fmt.allocPrint(arena, no_output_template, .{
                testcase.path,
            }) catch @panic("OOM");
            try output.appendSlice(body);
        },
        .expected_output_path => {
            const body = std.fmt.allocPrint(arena, expect_file_template, .{
                testcase.path,
                testcase.result.expected_output_path,
            }) catch @panic("OOM");
            try output.appendSlice(body);
        },
        .error_expected => {
            const body = std.fmt.allocPrint(arena, expect_err_template, .{
                testcase.path,
            }) catch @panic("OOM");
            try output.appendSlice(body);
        },
    }

    try output.appendSlice("}\n\n");
}

fn canAccess(dir: fs.Dir, file_path: []const u8) bool {
    if (dir.access(file_path, .{})) {
        return true;
    } else |_| {
        return false;
    }
}
