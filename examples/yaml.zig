const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const Yaml = @import("yaml").Yaml;

const mem = std.mem;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const usage =
    \\Usage: yaml <path-to-yaml>
    \\
    \\General options:
    \\--debug-log [scope]           Turn on debugging logs for [scope] (requires program compiled with -Dlog)
    \\-h, --help                    Print this help and exit
    \\
;

var log_scopes: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(gpa.allocator());

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Hide debug messages unless:
    // * logging enabled with `-Dlog`.
    // * the --debug-log arg for the scope has been provided
    if (@intFromEnum(level) > @intFromEnum(std.log.level) or
        @intFromEnum(level) > @intFromEnum(std.log.Level.info))
    {
        if (!build_options.enable_logging) return;

        const scope_name = @tagName(scope);
        for (log_scopes.items) |log_scope| {
            if (mem.eql(u8, log_scope, scope_name)) break;
        } else return;
    }

    // We only recognize 4 log levels in this application.
    const level_txt = switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const prefix1 = level_txt;
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const all_args = try std.process.argsAlloc(allocator);
    const args = all_args[1..];

    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    var file_path: ?[]const u8 = null;
    var arg_index: usize = 0;
    while (arg_index < args.len) : (arg_index += 1) {
        if (mem.eql(u8, "-h", args[arg_index]) or mem.eql(u8, "--help", args[arg_index])) {
            return stdout.writeAll(usage);
        } else if (mem.eql(u8, "--debug-log", args[arg_index])) {
            if (arg_index + 1 >= args.len) {
                return stderr.writeAll("fatal: expected [scope] after --debug-log\n\n");
            }
            arg_index += 1;
            if (!build_options.enable_logging) {
                try stderr.writeAll("warn: --debug-log will have no effect as program was not built with -Dlog\n\n");
            } else {
                try log_scopes.append(args[arg_index]);
            }
        } else {
            file_path = args[arg_index];
        }
    }

    if (file_path == null) {
        return stderr.writeAll("fatal: no input path to yaml file specified\n\n");
    }

    const file = try std.fs.cwd().openFile(file_path.?, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));

    var yaml: Yaml = .{ .source = source };
    defer yaml.deinit(allocator);

    yaml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => {
            assert(yaml.parse_errors.errorMessageCount() > 0);
            yaml.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(stderr) });
            return error.ParseFailure;
        },
        else => return err,
    };

    var writer = stdout.writer(&[0]u8{});
    try yaml.stringify(&writer.interface);
}
