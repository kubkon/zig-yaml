const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;
const log = std.log.scoped(.yaml);

const Allocator = mem.Allocator;

pub const Tokenizer = @import("Tokenizer.zig");
pub const parse = @import("parse.zig");

const Node = parse.Node;
const Tree = parse.Tree;
const ParseError = parse.ParseError;

pub const YamlError = error{UnexpectedNodeType} || ParseError;

pub const Value = union(enum) {
    empty,
    string: []const u8,
    list: []Value,
    map: std.StringArrayHashMapUnmanaged(Value),

    fn deinit(self: *Value, allocator: *Allocator) void {
        switch (self.*) {
            .list => |arr| {
                for (arr) |*value| {
                    value.deinit(allocator);
                }
                allocator.free(arr);
            },
            .map => |*m| {
                for (m.values()) |*value| {
                    value.deinit(allocator);
                }
                m.deinit(allocator);
            },
            else => {},
        }
    }

    fn fromNode(allocator: *Allocator, tree: *const Tree, node: *const Node) YamlError!Value {
        if (node.cast(Node.Doc)) |doc| {
            const inner = doc.value orelse {
                // empty doc
                return Value{ .empty = .{} };
            };
            return Value.fromNode(allocator, tree, inner);
        } else if (node.cast(Node.Map)) |map| {
            var out_map: std.StringArrayHashMapUnmanaged(Value) = .{};
            errdefer out_map.deinit(allocator);

            try out_map.ensureUnusedCapacity(allocator, map.values.items.len);

            for (map.values.items) |entry| {
                const key_tok = tree.tokens[entry.key];
                const key = tree.source[key_tok.start..key_tok.end];
                const value = try Value.fromNode(allocator, tree, entry.value);

                out_map.putAssumeCapacityNoClobber(key, value);
            }

            return Value{ .map = out_map };
        } else if (node.cast(Node.List)) |list| {
            var out_list = std.ArrayList(Value).init(allocator);
            errdefer out_list.deinit();

            try out_list.ensureUnusedCapacity(list.values.items.len);

            for (list.values.items) |elem| {
                const value = try Value.fromNode(allocator, tree, elem);
                out_list.appendAssumeCapacity(value);
            }

            return Value{ .list = out_list.toOwnedSlice() };
        } else if (node.cast(Node.Value)) |value| {
            const tok = tree.tokens[value.value.?];
            const string = tree.source[tok.start..tok.end];
            return Value{ .string = string };
        } else {
            log.err("Unexpected node type: {}", .{node.tag});
            return error.UnexpectedNodeType;
        }
    }
};

pub const Yaml = struct {
    allocator: *Allocator,
    tree: ?Tree = null,
    docs: std.ArrayListUnmanaged(Value) = .{},

    pub fn init(allocator: *Allocator) Yaml {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Yaml) void {
        if (self.tree) |*tree| {
            tree.deinit();
        }
        for (self.docs.items) |*value| {
            value.deinit(self.allocator);
        }
        self.docs.deinit(self.allocator);
    }

    pub fn load(self: *Yaml, source: []const u8) !void {
        var tree = Tree.init(self.allocator);
        try tree.parse(source);

        try self.docs.ensureUnusedCapacity(self.allocator, tree.docs.items.len);
        for (tree.docs.items) |node| {
            const value = try Value.fromNode(self.allocator, &tree, node);
            self.docs.appendAssumeCapacity(value);
        }

        self.tree = tree;
    }
};

test "" {
    testing.refAllDecls(@This());
}

test "simple list" {
    const source =
        \\- a
        \\- b
        \\- c
    ;

    var yaml = Yaml.init(testing.allocator);
    defer yaml.deinit();
    try yaml.load(source);

    try testing.expectEqual(yaml.docs.items.len, 1);

    const list = yaml.docs.items[0].list;
    try testing.expectEqual(list.len, 3);

    try testing.expect(mem.eql(u8, list[0].string, "a"));
    try testing.expect(mem.eql(u8, list[1].string, "b"));
    try testing.expect(mem.eql(u8, list[2].string, "c"));
}
