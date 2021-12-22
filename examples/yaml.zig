const std = @import("std");
const yaml = @import("yaml");

const io = std.io;
const mem = std.mem;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const usage =
    \\Usage: yaml <path-to-yaml>
    \\
    \\General options:
    \\-h, --help    Print this help and exit
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len == 1) {
        try io.getStdErr().writeAll("fatal: no input path to yaml file specified");
        try io.getStdOut().writeAll(usage);
        return;
    }

    if (mem.eql(u8, "-h", args[1]) or mem.eql(u8, "--help", args[1])) {
        try io.getStdOut().writeAll(usage);
        return;
    } else {
        const file_path = args[1];
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));

        var parsed = try yaml.Yaml.load(allocator, source);
        try parsed.stringify(io.getStdOut().writer());
    }
}
