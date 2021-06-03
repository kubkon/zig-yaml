const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;

pub const Tokenizer = @import("Tokenizer.zig");
pub const parse = @import("parse.zig");

pub const Value = union(enum) {
    string: []const u8,
};

pub fn load(allocator: *Allocator, source: []const u8) !std.ArrayList(Value) {
    var parsed = std.ArrayList(Value).init(allocator);
    errdefer parsed.deinit();

    var tree = parse.Tree.init(allocator);
    defer tree.deinit();

    try tree.parse(source);

    return parsed;
}

test "" {
    testing.refAllDecls(@This());
}
