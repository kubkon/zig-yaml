const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Yaml = @import("yaml").Yaml;

const allocator = testing.allocator;

fn testYaml(
    file_path: []const u8,
    comptime T: type,
    eql: fn (T, T) bool,
    expected: T,
) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(source);

    var parsed = try Yaml.load(allocator, source);
    defer parsed.deinit();

    const result = try parsed.parse(T);
    try testing.expect(eql(expected, result));
}

test "simple" {
    const Simple = struct {
        names: [3][]const u8,
        numbers: [3]u16,
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

            return true;
        }
    };

    try testYaml("test/simple.yaml", Simple, Simple.eql, Simple{
        .names = [_][]const u8{ "John Doe", "MacIntosh", "Jane Austin" },
        .numbers = [_]u16{ 10, 8, 6 },
        .finally = [_]f16{ 8.17, 19.78, 17, 21 },
    });
}
