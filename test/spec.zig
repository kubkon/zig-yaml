const std = @import("std");
const Step = std.Build.Step;
const fs = std.fs;
const mem = std.mem;

const Aegis128LMac_128 = std.crypto.auth.aegis.Aegis128LMac_128;

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

const Testcase = struct { name: []const u8, path: []const u8, result: union(enum) { expected_output_path: []const u8, error_expected, none }, tags: std.BufSet };

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

    var testcases = std.StringArrayHashMap(Testcase).init(b.allocator);
    defer testcases.deinit();

    const root_data_path = fs.path.join(b.allocator, &[_][]const u8{
        b.build_root.path.?,
        "test/yaml-test-suite",
    }) catch unreachable;

    const root_data_dir = try std.fs.openDirAbsolute(root_data_path, .{});

    var itdir = try root_data_dir.openDir("tags", .{ .iterate = true, .access_sub_paths = true });

    var walker = try itdir.walk(b.allocator);
    defer walker.deinit();
    loop: {
        while (walker.next()) |entry| {
            if (entry) |e| {
                if (collectTest(b.allocator, e, &testcases)) |_| {} else |_| {}
            } else {
                break :loop;
            }
        } else |err| {
            std.debug.print("err: {}", .{err});
            break :loop;
        }
    }

    var output = std.ArrayList(u8).init(b.allocator);
    defer output.deinit();
    const writer = output.writer();
    try writer.writeAll(preamble);

    while (testcases.popOrNull()) |kv| {
        b.allocator.free(kv.key);
        try emitTest(b.allocator, &output, kv.value);
        b.allocator.free(kv.value.name);
        var tags = kv.value.tags;
        tags.deinit();
        b.allocator.free(kv.value.path);
        if (kv.value.result == .expected_output_path) {
            b.allocator.free(kv.value.result.expected_output_path);
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

fn collectTest(alloc: mem.Allocator, entry: fs.Dir.Walker.Entry, testcases: *std.StringArrayHashMap(Testcase)) !void {
    if (entry.kind != .sym_link) {
        return;
    }
    var path_components = std.fs.path.componentIterator(entry.path) catch unreachable;
    const first_path = path_components.first().?;

    var remaining_path = alloc.alloc(u8, 0) catch @panic("OOM");
    while (path_components.next()) |component| {
        const new_path = fs.path.join(alloc, &[_][]const u8{
            remaining_path,
            component.name,
        }) catch @panic("OOM");
        alloc.free(remaining_path);
        remaining_path = new_path;
    }

    const result = try testcases.getOrPut(remaining_path);
    if (!result.found_existing) {
        const key_alloc: []u8 = try alloc.dupe(u8, remaining_path);
        result.key_ptr.* = key_alloc;

        const in_path = fs.path.join(alloc, &[_][]const u8{
            entry.basename,
            "in.yaml",
        }) catch @panic("OOM");
        const real_in_path = try entry.dir.realpathAlloc(alloc, in_path);

        const name_file_path = fs.path.join(alloc, &[_][]const u8{
            entry.basename,
            "===",
        }) catch @panic("OOM");
        const name_file = entry.dir.openFile(name_file_path, .{}) catch unreachable;
        defer name_file.close();
        const name = try name_file.readToEndAlloc(alloc, std.math.maxInt(u32));
        defer alloc.free(name);

        var tag_set = std.BufSet.init(alloc);
        tag_set.insert(first_path.name) catch @panic("OOM");

        const full_name = std.fmt.allocPrint(alloc, "{s} - {s}", .{ remaining_path, name[0 .. name.len - 1] }) catch @panic("OOM");

        result.value_ptr.* = .{
            .name = full_name,
            .path = real_in_path,
            .result = .{ .none = {} },
            .tags = tag_set,
        };

        const out_path = fs.path.join(alloc, &[_][]const u8{
            entry.basename,
            "out.yaml",
        }) catch @panic("OOM");
        const err_path = fs.path.join(alloc, &[_][]const u8{
            entry.basename,
            "error",
        }) catch @panic("OOM");
        if (canAccess(entry.dir, out_path)) {
            const real_out_path = try entry.dir.realpathAlloc(alloc, out_path);
            result.value_ptr.result = .{ .expected_output_path = real_out_path };
        } else if (canAccess(entry.dir, err_path)) {
            result.value_ptr.result = .{ .error_expected = {} };
        }
    } else {
        result.value_ptr.tags.insert(first_path.name) catch @panic("OOM");
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

fn emitTest(alloc: mem.Allocator, output: *std.ArrayList(u8), testcase: Testcase) !void {
    const head = std.fmt.allocPrint(alloc, "test \"{}\" {{\n", .{std.zig.fmtEscapes(testcase.name)}) catch @panic("OOM");
    defer alloc.free(head);
    try output.appendSlice(head);

    switch (testcase.result) {
        .none => {
            const body = std.fmt.allocPrint(alloc, no_output_template, .{testcase.path}) catch @panic("OOM");
            defer alloc.free(body);
            try output.appendSlice(body);
        },
        .expected_output_path => {
            const body = std.fmt.allocPrint(alloc, expect_file_template, .{ testcase.path, testcase.result.expected_output_path }) catch @panic("OOM");
            defer alloc.free(body);
            try output.appendSlice(body);
        },
        .error_expected => {
            const body = std.fmt.allocPrint(alloc, expect_err_template, .{testcase.path}) catch @panic("OOM");
            defer alloc.free(body);
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
