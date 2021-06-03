const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;

pub const Tokenizer = @import("Tokenizer.zig");
pub const parse = @import("parse.zig");

const Node = parse.Node;
const Tree = parse.Tree;

pub const Value = union(enum) {
    string: []const u8,
    array: []Value,
    map: std.StringArrayHashMapUnmanaged(Value),

    fn deinit(self: *Value, allocator: *Allocator) void {
        switch (self.*) {
            .array => |arr| {
                for (arr) |*value| {
                    value.deinit(allocator);
                }
                allocator.free(arr);
            },
            .map => |*m| {
                for (m.items()) |*value| {
                    value.value.deinit(allocator);
                }
                m.deinit(allocator);
            },
            else => {},
        }
    }

    fn fromNode(allocator: *Allocator, node: *const Node) !Value {
        if (node.constCast(Node.Doc)) |doc| {
            var map: std.StringArrayHashMapUnmanaged(Value) = .{};
            errdefer map.deinit(allocator);

            if (doc.directive) |tok_id| {
                const token = node.tree.tokens[tok_id];
                assert(token.id == .Literal);
                const directive = node.tree.source[token.start..token.end];
                try map.putNoClobber(allocator, "directive", .{
                    .string = directive,
                });
            }

            // TODO handle values

            return Value{ .map = map };
        } else {
            return error.Unhandled;
        }
    }
};

pub const Yaml = struct {
    allocator: *Allocator,
    docs: std.ArrayListUnmanaged(Value) = .{},

    pub fn deinit(self: *Yaml) void {
        for (self.docs.items) |*value| {
            value.deinit(self.allocator);
        }
        self.docs.deinit(self.allocator);
    }
};

pub fn load(allocator: *Allocator, source: []const u8) !Yaml {
    var yaml = Yaml{ .allocator = allocator };
    errdefer yaml.deinit();

    var tree = Tree.init(allocator);
    defer tree.deinit();

    try tree.parse(source);

    try yaml.docs.ensureUnusedCapacity(allocator, tree.root.docs.items.len);
    for (tree.root.docs.items) |node| {
        const value = try Value.fromNode(allocator, node);
        yaml.docs.appendAssumeCapacity(value);
    }

    return yaml;
}

test "" {
    testing.refAllDecls(@This());
}

test "empty doc" {
    const source =
        \\--- !tapi-tbd
        \\...
    ;

    var yaml = try load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const doc = yaml.docs.items[0].map;
    try testing.expect(doc.contains("directive"));
    try testing.expect(mem.eql(u8, doc.get("directive").?.string, "tapi-tbd"));
}
