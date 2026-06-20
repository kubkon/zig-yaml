const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const Yaml = @import("yaml").Yaml;

const mem = std.mem;

const usage =
    \\Usage: yaml <path-to-yaml>
    \\
    \\General options:
    \\--debug-log [scope]           Turn on debugging logs for [scope] (requires program compiled with -Dlog)
    \\-h, --help                    Print this help and exit
    \\
;

var log_scopes: std.ArrayList([]const u8) = .empty;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Hide debug messages unless:
    // * logging enabled with `-Dlog`.
    // * the --debug-log arg for the scope has been provided
    if (@intFromEnum(level) > @intFromEnum(std.options.log_level) or
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

pub const std_options: std.Options = .{ .logFn = logFn };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    
    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);
    defer log_scopes.deinit(allocator);
    
    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    
    // 跳过第一个参数（程序名）
    _ = args_iter.next();
    
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch continue;
    }
    const args = args_list.items;

    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();
    const stdout_writer = stdout.writer();
    const stderr_writer = stderr.writer();

    var file_path: ?[]const u8 = null;
    var arg_index: usize = 0;
    while (arg_index < args.len) : (arg_index += 1) {
        if (mem.eql(u8, "-h", args[arg_index]) or mem.eql(u8, "--help", args[arg_index])) {
            return stdout_writer.writeAll(usage);
        } else if (mem.eql(u8, "--debug-log", args[arg_index])) {
            if (arg_index + 1 >= args.len) {
                return stderr_writer.writeAll("fatal: expected [scope] after --debug-log\n\n");
            }
            arg_index += 1;
            if (!build_options.enable_logging) {
                try stderr_writer.writeAll("warn: --debug-log will have no effect as program was not built with -Dlog\n\n");
            } else {
                try log_scopes.append(allocator, args[arg_index]);
            }
        } else {
            file_path = args[arg_index];
        }
    }

    if (file_path == null) {
        return stderr_writer.writeAll("fatal: no input path to yaml file specified\n\n");
    }

    var io_instance = std.Io.Threaded.init(allocator, .{});
    const io = io_instance.io();
    
    const file = try std.Io.Dir.cwd().openFileIo(io, file_path.?, .{});
    defer file.close(io);

    const size = try file.length(io);
    var source = try std.ArrayList(u8).initCapacity(allocator, size);
    source.items.len = size;
    _ = try file.readStreaming(io, &[_][]u8{source.items});

    var yaml: Yaml = .{ .source = source.items };
    defer yaml.deinit(allocator);

    yaml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => {
            assert(yaml.parse_errors.errorMessageCount() > 0);
            yaml.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(stderr) });
            return error.ParseFailure;
        },
        else => return err,
    };

    var writer = std.Io.Writer.fixed(stdout);
    try yaml.stringify(&writer);
}