const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const log = std.log.scoped(.yaml);

const Allocator = mem.Allocator;

pub const Tokenizer = @import("Tokenizer.zig");
pub const parse = @import("parse.zig");

const Node = parse.Node;
const Tree = parse.Tree;
const ParseError = parse.ParseError;

pub const YamlError = error{UnexpectedNodeType} || ParseError || std.fmt.ParseIntError;

pub const ValueType = enum { empty, int, float, string, list, map };

pub const Value = union(ValueType) {
    empty,
    int: i64,
    float: f64,
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

    fn fromNode(allocator: *Allocator, tree: *const Tree, node: *const Node, type_hint: ?ValueType) YamlError!Value {
        if (node.cast(Node.Doc)) |doc| {
            const inner = doc.value orelse {
                // empty doc
                return Value{ .empty = .{} };
            };
            return Value.fromNode(allocator, tree, inner, null);
        } else if (node.cast(Node.Map)) |map| {
            var out_map: std.StringArrayHashMapUnmanaged(Value) = .{};
            errdefer out_map.deinit(allocator);

            try out_map.ensureUnusedCapacity(allocator, map.values.items.len);

            for (map.values.items) |entry| {
                const key_tok = tree.tokens[entry.key];
                const key = tree.source[key_tok.start..key_tok.end];
                const value = try Value.fromNode(allocator, tree, entry.value, null);

                out_map.putAssumeCapacityNoClobber(key, value);
            }

            return Value{ .map = out_map };
        } else if (node.cast(Node.List)) |list| {
            var out_list = std.ArrayList(Value).init(allocator);
            errdefer out_list.deinit();

            try out_list.ensureUnusedCapacity(list.values.items.len);

            if (list.values.items.len > 0) {
                const hint = if (list.values.items[0].cast(Node.Value)) |value| hint: {
                    const elem = list.values.items[0];
                    const start = tree.tokens[value.start.?];
                    const end = tree.tokens[value.end.?];
                    const raw = tree.source[start.start..end.end];
                    _ = std.fmt.parseInt(i64, raw, 10) catch {
                        _ = std.fmt.parseFloat(f64, raw) catch {
                            break :hint ValueType.string;
                        };
                        break :hint ValueType.float;
                    };
                    break :hint ValueType.int;
                } else null;

                for (list.values.items) |elem| {
                    const value = try Value.fromNode(allocator, tree, elem, hint);
                    out_list.appendAssumeCapacity(value);
                }
            }

            return Value{ .list = out_list.toOwnedSlice() };
        } else if (node.cast(Node.Value)) |value| {
            const start = tree.tokens[value.start.?];
            const end = tree.tokens[value.end.?];
            const raw = tree.source[start.start..end.end];

            if (type_hint) |hint| {
                return switch (hint) {
                    .int => Value{ .int = try std.fmt.parseInt(i64, raw, 10) },
                    .float => Value{ .float = try std.fmt.parseFloat(f64, raw) },
                    .string => Value{ .string = raw },
                    else => unreachable,
                };
            }

            try_int: {
                // TODO infer base for int
                const int = std.fmt.parseInt(i64, raw, 10) catch break :try_int;
                return Value{ .int = int };
            }
            try_float: {
                const float = std.fmt.parseFloat(f64, raw) catch break :try_float;
                return Value{ .float = float };
            }
            return Value{ .string = raw };
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
            const value = try Value.fromNode(allocator, &tree, node, null);
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
        Overflow,
    };

    pub fn parse(self: *const Yaml, comptime T: type) Error!T {
        if (self.docs.items.len == 0) return error.EmptyYaml;
        if (self.docs.items.len > 1) return error.MultiDocUnsupported;

        switch (@typeInfo(T)) {
            .Struct => return self.parseStruct(T, self.docs.items[0].map),
            .Array => return self.parseArray(T, self.docs.items[0].list),
            .Void => unreachable,
            else => @compileError("unimplemented for " ++ @typeName(T)),
        }
    }

    fn parseStruct(self: *const Yaml, comptime T: type, map: anytype) Error!T {
        const struct_info = @typeInfo(T).Struct;
        var parsed: T = undefined;

        inline for (struct_info.fields) |field| {
            const value = map.get(field.name) orelse return error.StructFieldMissing;

            switch (@typeInfo(field.field_type)) {
                .Int => {
                    @field(parsed, field.name) = try math.cast(field.field_type, value.int);
                },
                .Float => {
                    @field(parsed, field.name) = math.lossyCast(field.field_type, value.float);
                },
                .Pointer => |ptr_info| {
                    switch (ptr_info.size) {
                        .One => @compileError("unimplemented for pointer to " ++ @typeName(ptr_info.child)),
                        .Slice => {
                            switch (@typeInfo(ptr_info.child)) {
                                .Int => |int_info| {
                                    if (int_info.bits == 8) {
                                        @field(parsed, field.name) = value.string;
                                    } else {
                                        @field(parsed, field.name) = try math.cast(field.field_type, value.int);
                                    }
                                },
                                .Float => {
                                    @field(parsed, field.name) = math.lossyCast(field.field_type, value.float);
                                },
                                else => @compileError("unimplemented for " ++ @typeName(ptr_info.child)),
                            }
                        },
                        else => @compileError("unimplemented for pointer to many " ++ @typeName(ptr_info.child)),
                    }
                },
                .Array => {
                    @field(parsed, field.name) = try self.parseArray(field.field_type, value.list);
                },
                .Struct => {
                    @field(parsed, field.name) = try self.parseStruct(field.field_type, value.map);
                },
                else => @compileError("unimplemented for " ++ @typeName(field.field_type)),
            }
        }

        return parsed;
    }

    fn parseArray(self: *const Yaml, comptime T: type, list: []Value) Error!T {
        const array_info = @typeInfo(T).Array;
        if (array_info.len != list.len) return error.ArraySizeMismatch;

        var parsed: T = undefined;
        switch (@typeInfo(array_info.child)) {
            .Int => {
                for (list) |value, i| {
                    parsed[i] = try math.cast(array_info.child, value.int);
                }
            },
            .Float => {
                for (list) |value, i| {
                    parsed[i] = math.lossyCast(array_info.child, value.float);
                }
            },
            .Pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .One => @compileError("unimplemented for pointer to " ++ @typeName(ptr_info.child)),
                    .Slice => {
                        switch (@typeInfo(ptr_info.child)) {
                            .Int => |int_info| {
                                if (int_info.bits == 8) {
                                    for (list) |value, i| {
                                        parsed[i] = value.string;
                                    }
                                } else {
                                    for (list) |value, i| {
                                        parsed[i] = try math.cast(field.field_type, value.int);
                                    }
                                }
                            },
                            .Float => {
                                for (list) |value, i| {
                                    parsed[i] = math.lossyCast(field.field_type, value.float);
                                }
                            },
                            else => @compileError("unimplemented for " ++ @typeName(ptr_info.child)),
                        }
                    },
                    else => @compileError("unimplemented for pointer to many " ++ @typeName(ptr_info.child)),
                }
            },
            else => @compileError("unimplemented for " ++ @typeName(array_info.child)),
        }

        return parsed;
    }
};

test {
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

test "simple list typed as array of strings" {
    const source =
        \\- a
        \\- b
        \\- c
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3][]const u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expect(mem.eql(u8, arr[0], "a"));
    try testing.expect(mem.eql(u8, arr[1], "b"));
    try testing.expect(mem.eql(u8, arr[2], "c"));
}

test "simple list typed as array of ints" {
    const source =
        \\- 0
        \\- 1
        \\- 2
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3]u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expectEqual(arr[0], 0);
    try testing.expectEqual(arr[1], 1);
    try testing.expectEqual(arr[2], 2);
}

test "list of mixed sign integer" {
    const source =
        \\- 0
        \\- -1
        \\- 2
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3]i8);
    try testing.expectEqual(arr.len, 3);
    try testing.expectEqual(arr[0], 0);
    try testing.expectEqual(arr[1], -1);
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
    try testing.expectEqual(map.get("a").?.int, 0);
}

test "simple map typed" {
    const source =
        \\a: 0
        \\b: hello there
        \\c: 'wait, what?'
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const simple = try yaml.parse(struct { a: usize, b: []const u8, c: []const u8 });
    try testing.expectEqual(simple.a, 0);
    try testing.expect(mem.eql(u8, simple.b, "hello there"));
    try testing.expect(mem.eql(u8, simple.c, "wait, what?"));
}

test "typed nested structs" {
    const source =
        \\a:
        \\  b: hello there
        \\  c: 'wait, what?'
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const simple = try yaml.parse(struct {
        a: struct {
            b: []const u8,
            c: []const u8,
        },
    });
    try testing.expect(mem.eql(u8, simple.a.b, "hello there"));
    try testing.expect(mem.eql(u8, simple.a.c, "wait, what?"));
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
