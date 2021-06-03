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
            if (doc.values.items.len == 0) {
                // empty doc; represent as empty map.
                return std.StringArrayHashMapUnmanaged{};
            }

            // var map: std.StringArrayHashMapUnmanaged(Value) = .{};
            // errdefer map.deinit(allocator);

            // if (doc.values.items.len > 0) {
            // var list = try allocator.alloc(Value, doc.values.items.len);
            // errdefer allocator.free(list);

            // for (doc.values.items) |node, i| {
            //     const value = try Value.fromNode(node);
            //     list[i] = value;
            // }

            // try map.putNoClobber(allocator, )

            // }

            // return Value{ .map = map };
            return error.Unhandled;
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

    // try yaml.docs.ensureUnusedCapacity(allocator, tree.docs.items.len);
    // for (tree.docs.items) |node| {
    //     const value = try Value.fromNode(allocator, node);
    //     yaml.docs.appendAssumeCapacity(value);
    // }

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

    // var yaml = try load(testing.allocator, source);
    // defer yaml.deinit();

    // try testing.expectEqual(yaml.docs.items.len, 1);
}
