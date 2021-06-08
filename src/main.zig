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

    pub fn deinit(self: *Yaml) void {
        if (self.tree) |*tree| {
            tree.deinit();
        }
        for (self.docs.items) |*value| {
            value.deinit(self.allocator);
        }
        self.docs.deinit(self.allocator);
    }

    pub fn load(allocator: *Allocator, source: []const u8) !Yaml {
        var tree = Tree.init(allocator);
        errdefer tree.deinit();

        try tree.parse(source);

        var docs: std.ArrayListUnmanaged(Value) = .{};
        errdefer docs.deinit(allocator);

        try docs.ensureUnusedCapacity(allocator, tree.docs.items.len);
        for (tree.docs.items) |node| {
            const value = try Value.fromNode(allocator, &tree, node);
            docs.appendAssumeCapacity(value);
        }

        return Yaml{
            .allocator = allocator,
            .tree = tree,
            .docs = docs,
        };
    }

    pub const Error = error{
        EmptyYaml,
        MultiDocUnsupported,
        StructFieldMissing,
        ArraySizeMismatch,
    } || std.fmt.ParseIntError;

    pub fn parse(self: *Yaml, comptime T: type) Error!T {
        if (self.docs.items.len == 0) return error.EmptyYaml;
        if (self.docs.items.len > 1) return error.MultiDocUnsupported;

        switch (@typeInfo(T)) {
            .Struct => |struct_info| {
                const map = self.docs.items[0].map;
                var parsed: T = undefined;

                inline for (struct_info.fields) |field| {
                    const value = map.get(field.name) orelse return error.StructFieldMissing;

                    switch (@typeInfo(field.field_type)) {
                        .Int => {
                            @field(parsed, field.name) = try std.fmt.parseInt(field.field_type, value.string, 10);
                        },
                        else => @compileError("unimplemented"),
                    }
                }

                return parsed;
            },
            .Array => |array_info| {
                const list = self.docs.items[0].list;

                if (array_info.len != list.len) return error.ArraySizeMismatch;

                var parsed: T = undefined;
                switch (@typeInfo(array_info.child)) {
                    .Int => {
                        for (list) |value, i| {
                            parsed[i] = try std.fmt.parseInt(array_info.child, value.string, 10);
                        }
                    },
                    else => @compileError("unimplemented"),
                }

                return parsed;
            },
            .Void => unreachable,
            else => @compileError("unimplemented"),
        }
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

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const list = yaml.docs.items[0].list;
    try testing.expectEqual(list.len, 3);

    try testing.expect(mem.eql(u8, list[0].string, "a"));
    try testing.expect(mem.eql(u8, list[1].string, "b"));
    try testing.expect(mem.eql(u8, list[2].string, "c"));
}

test "simple list typed as array" {
    const source =
        \\- 0
        \\- 1
        \\- 2
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3]usize);
    try testing.expectEqual(arr.len, 3);
    try testing.expectEqual(arr[0], 0);
    try testing.expectEqual(arr[1], 1);
    try testing.expectEqual(arr[2], 2);
}

test "simple map untyped" {
    const source =
        \\a: 0
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const map = yaml.docs.items[0].map;
    try testing.expect(map.contains("a"));
    try testing.expect(mem.eql(u8, map.get("a").?.string, "0"));
}

test "simple map typed" {
    const source =
        \\a: 0
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const simple = try yaml.parse(struct { a: usize });
    try testing.expectEqual(simple.a, 0);
}

test "multidoc typed not supported yet" {
    const source =
        \\---
        \\a: 0
        \\...
        \\---
        \\- 0
        \\...
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectError(Yaml.Error.MultiDocUnsupported, yaml.parse(struct { a: usize }));
    try testing.expectError(Yaml.Error.MultiDocUnsupported, yaml.parse([1]usize));
}

test "empty yaml typed not supported" {
    const source = "";
    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();
    try testing.expectError(Yaml.Error.EmptyYaml, yaml.parse(void));
}

test "typed array size mismatch" {
    const source =
        \\- 0
        \\- 0
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectError(Yaml.Error.ArraySizeMismatch, yaml.parse([1]usize));
    try testing.expectError(Yaml.Error.ArraySizeMismatch, yaml.parse([5]usize));
}

test "typed struct missing field" {
    const source =
        \\bar: 10
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectError(Yaml.Error.StructFieldMissing, yaml.parse(struct { foo: usize }));
    try testing.expectError(Yaml.Error.StructFieldMissing, yaml.parse(struct { foobar: usize }));
}
