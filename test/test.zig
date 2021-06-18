const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Yaml = @import("yaml").Yaml;

const gpa = testing.allocator;

fn loadFromFile(file_path: []const u8) !Yaml {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(gpa, std.math.maxInt(u32));
    defer gpa.free(source);

    return Yaml.load(gpa, source);
}

test "simple" {
    const Simple = struct {
        names: []const []const u8,
        numbers: []const i16,
        nested: struct {
            some: []const u8,
            wick: []const u8,
        },
        finally: [4]f16,

        pub fn eql(self: @This(), other: @This()) bool {
            if (self.names.len != other.names.len) return false;
            if (self.numbers.len != other.numbers.len) return false;
            if (self.finally.len != other.finally.len) return false;

            for (self.names) |lhs, i| {
                if (!mem.eql(u8, lhs, other.names[i])) return false;
            }

            for (self.numbers) |lhs, i| {
                if (lhs != other.numbers[i]) return false;
            }

            for (self.finally) |lhs, i| {
                if (lhs != other.finally[i]) return false;
            }

            if (!mem.eql(u8, self.nested.some, other.nested.some)) return false;
            if (!mem.eql(u8, self.nested.wick, other.nested.wick)) return false;

            return true;
        }
    };

    var parsed = try loadFromFile("test/simple.yaml");
    defer parsed.deinit();

    const result = try parsed.parse(Simple);
    const expected = .{
        .names = &[_][]const u8{ "John Doe", "MacIntosh", "Jane Austin" },
        .numbers = &[_]i16{ 10, -8, 6 },
        .nested = .{
            .some = "one",
            .wick = "john doe",
        },
        .finally = [_]f16{ 8.17, 19.78, 17, 21 },
    };
    try testing.expect(result.eql(expected));
}

const LibTbd = struct {
    tbd_version: u3,
    targets: []const []const u8,
    uuids: []const struct {
        target: []const u8,
        value: []const u8,
    },
    install_name: []const u8,
    current_version: union(enum) {
        string: []const u8,
        int: usize,
    },
    reexported_libraries: ?[]const struct {
        targets: []const []const u8,
        libraries: []const []const u8,
    },
    parent_umbrella: ?[]const struct {
        targets: []const []const u8,
        umbrella: []const u8,
    },
    exports: []const struct {
        targets: []const []const u8,
        symbols: []const []const u8,
    },

    pub fn eql(self: LibTbd, other: LibTbd) bool {
        if (self.tbd_version != other.tbd_version) return false;
        if (self.targets.len != other.targets.len) return false;

        for (self.targets) |target, i| {
            if (!mem.eql(u8, target, other.targets[i])) return false;
        }

        if (!mem.eql(u8, self.install_name, other.install_name)) return false;

        switch (self.current_version) {
            .string => |string| {
                if (other.current_version != .string) return false;
                if (!mem.eql(u8, string, other.current_version.string)) return false;
            },
            .int => |int| {
                if (other.current_version != .int) return false;
                if (int != other.current_version.int) return false;
            },
        }

        if (self.reexported_libraries) |reexported_libraries| {
            const o_reexported_libraries = other.reexported_libraries orelse return false;

            if (reexported_libraries.len != o_reexported_libraries.len) return false;

            for (reexported_libraries) |reexport, i| {
                const o_reexport = o_reexported_libraries[i];
                if (reexport.targets.len != o_reexport.targets.len) return false;
                if (reexport.libraries.len != o_reexport.libraries.len) return false;

                for (reexport.targets) |target, j| {
                    const o_target = o_reexport.targets[j];
                    if (!mem.eql(u8, target, o_target)) return false;
                }

                for (reexport.libraries) |library, j| {
                    const o_library = o_reexport.libraries[j];
                    if (!mem.eql(u8, library, o_library)) return false;
                }
            }
        }

        if (self.parent_umbrella) |parent_umbrella| {
            const o_parent_umbrella = other.parent_umbrella orelse return false;

            if (parent_umbrella.len != o_parent_umbrella.len) return false;

            for (parent_umbrella) |pumbrella, i| {
                const o_pumbrella = o_parent_umbrella[i];
                if (pumbrella.targets.len != o_pumbrella.targets.len) return false;

                for (pumbrella.targets) |target, j| {
                    const o_target = o_pumbrella.targets[j];
                    if (!mem.eql(u8, target, o_target)) return false;
                }

                if (!mem.eql(u8, pumbrella.umbrella, o_pumbrella.umbrella)) return false;
            }
        }

        if (self.exports.len != other.exports.len) return false;

        for (self.exports) |exp, i| {
            const o_exp = other.exports[i];
            if (exp.targets.len != o_exp.targets.len) return false;
            if (exp.symbols.len != o_exp.symbols.len) return false;

            for (exp.targets) |target, j| {
                const o_target = o_exp.targets[j];
                if (!mem.eql(u8, target, o_target)) return false;
            }

            for (exp.symbols) |symbol, j| {
                const o_symbol = o_exp.symbols[j];
                if (!mem.eql(u8, symbol, o_symbol)) return false;
            }
        }

        return true;
    }
};

test "single lib tbd" {
    var parsed = try loadFromFile("test/single_lib.tbd");
    defer parsed.deinit();

    const result = try parsed.parse(LibTbd);
    const expected = .{
        .tbd_version = 4,
        .targets = &[_][]const u8{
            "x86_64-macos",
            "x86_64-maccatalyst",
            "arm64-macos",
            "arm64-maccatalyst",
            "arm64e-macos",
            "arm64e-maccatalyst",
        },
        .uuids = &.{
            .{ .target = "x86_64-macos", .value = "F86CC732-D5E4-30B5-AA7D-167DF5EC2708" },
            .{ .target = "x86_64-maccatalyst", .value = "F86CC732-D5E4-30B5-AA7D-167DF5EC2708" },
            .{ .target = "arm64-macos", .value = "00000000-0000-0000-0000-000000000000" },
            .{ .target = "arm64-maccatalyst", .value = "00000000-0000-0000-0000-000000000000" },
            .{ .target = "arm64e-macos", .value = "A17E8744-051E-356E-8619-66F2A6E89AD4" },
            .{ .target = "arm64e-maccatalyst", .value = "A17E8744-051E-356E-8619-66F2A6E89AD4" },
        },
        .install_name = "/usr/lib/libSystem.B.dylib",
        .current_version = .{ .string = "1292.60.1" },
        .reexported_libraries = &.{
            .{
                .targets = &.{
                    "x86_64-macos",
                    "x86_64-maccatalyst",
                    "arm64-macos",
                    "arm64-maccatalyst",
                    "arm64e-macos",
                    "arm64e-maccatalyst",
                },
                .libraries = &.{
                    "/usr/lib/system/libcache.dylib",       "/usr/lib/system/libcommonCrypto.dylib",
                    "/usr/lib/system/libcompiler_rt.dylib", "/usr/lib/system/libcopyfile.dylib",
                    "/usr/lib/system/libxpc.dylib",
                },
            },
        },
        .exports = &.{
            .{
                .targets = &.{
                    "x86_64-maccatalyst",
                    "x86_64-macos",
                },
                .symbols = &.{
                    "R8289209$_close", "R8289209$_fork", "R8289209$_fsync", "R8289209$_getattrlist",
                    "R8289209$_write",
                },
            },
            .{
                .targets = &.{
                    "x86_64-maccatalyst",
                    "x86_64-macos",
                    "arm64e-maccatalyst",
                    "arm64e-macos",
                    "arm64-macos",
                    "arm64-maccatalyst",
                },
                .symbols = &.{
                    "___crashreporter_info__",   "_libSystem_atfork_child", "_libSystem_atfork_parent",
                    "_libSystem_atfork_prepare", "_mach_init_routine",
                },
            },
        },
        .parent_umbrella = null,
    };
    try testing.expect(result.eql(expected));
}

test "multi lib tbd" {
    var parsed = try loadFromFile("test/multi_lib.tbd");
    defer parsed.deinit();

    const result = try parsed.parse([]LibTbd);
    const expected = &[_]LibTbd{
        .{
            .tbd_version = 4,
            .targets = &[_][]const u8{"x86_64-macos"},
            .uuids = &.{
                .{ .target = "x86_64-macos", .value = "F86CC732-D5E4-30B5-AA7D-167DF5EC2708" },
            },
            .install_name = "/usr/lib/libSystem.B.dylib",
            .current_version = .{ .string = "1292.60.1" },
            .reexported_libraries = &.{
                .{
                    .targets = &.{"x86_64-macos"},
                    .libraries = &.{"/usr/lib/system/libcache.dylib"},
                },
            },
            .exports = &.{
                .{
                    .targets = &.{"x86_64-macos"},
                    .symbols = &.{ "R8289209$_close", "R8289209$_fork" },
                },
                .{
                    .targets = &.{"x86_64-macos"},
                    .symbols = &.{ "___crashreporter_info__", "_libSystem_atfork_child" },
                },
            },
            .parent_umbrella = null,
        },
        .{
            .tbd_version = 4,
            .targets = &[_][]const u8{"x86_64-macos"},
            .uuids = &.{
                .{ .target = "x86_64-macos", .value = "2F7F7303-DB23-359E-85CD-8B2F93223E2A" },
            },
            .install_name = "/usr/lib/system/libcache.dylib",
            .current_version = .{ .int = 83 },
            .parent_umbrella = &.{
                .{
                    .targets = &.{"x86_64-macos"},
                    .umbrella = "System",
                },
            },
            .exports = &.{
                .{
                    .targets = &.{"x86_64-macos"},
                    .symbols = &.{ "_cache_create", "_cache_destroy" },
                },
            },
            .reexported_libraries = null,
        },
    };

    for (result) |lib, i| {
        try testing.expect(lib.eql(expected[i]));
    }
}
