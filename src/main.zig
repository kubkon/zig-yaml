const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

pub const log_level: std.log.Level = .debug;

const log = std.log.scoped(.yaml);

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Tokenizer = @import("Tokenizer.zig");
pub const parse = @import("parse.zig");

const Node = parse.Node;
const Tree = parse.Tree;
const ParseError = parse.ParseError;

pub const YamlError = error{
    UnexpectedNodeType,
    OutOfMemory,
} || ParseError || std.fmt.ParseIntError;

pub const ValueType = enum {
    empty,
    int,
    float,
    string,
    list,
    map,
};

pub const List = []Value;
pub const Map = std.StringArrayHashMap(Value);

pub const Value = union(ValueType) {
    empty,
    int: i64,
    float: f64,
    string: []const u8,
    list: List,
    map: Map,

    fn fromNode(arena: *Allocator, tree: *const Tree, node: *const Node, type_hint: ?ValueType) YamlError!Value {
        if (node.cast(Node.Doc)) |doc| {
            const inner = doc.value orelse {
                // empty doc
                return Value{ .empty = .{} };
            };
            return Value.fromNode(arena, tree, inner, null);
        } else if (node.cast(Node.Map)) |map| {
            var out_map = std.StringArrayHashMap(Value).init(arena);
            try out_map.ensureUnusedCapacity(map.values.items.len);

            for (map.values.items) |entry| {
                const key_tok = tree.tokens[entry.key];
                const key = try arena.dupe(u8, tree.source[key_tok.start..key_tok.end]);
                const value = try Value.fromNode(arena, tree, entry.value, null);

                out_map.putAssumeCapacityNoClobber(key, value);
            }

            return Value{ .map = out_map };
        } else if (node.cast(Node.List)) |list| {
            var out_list = std.ArrayList(Value).init(arena);
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
                    const value = try Value.fromNode(arena, tree, elem, hint);
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
                    .string => switch (value.escape_mode) {
                        .None => Value{ .string = try arena.dupe(u8, raw) },
                        .DoubleQuote => Value{ .string = value.string_value.items },
                        .SingleQuote => Value{ .string = value.string_value.items },
                    },
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
            return Value{ .string = try arena.dupe(u8, raw) };
        } else {
            log.err("Unexpected node type: {}", .{node.tag});
            return error.UnexpectedNodeType;
        }
    }
};

pub const Yaml = struct {
    arena: ArenaAllocator,
    tree: ?Tree = null,
    docs: std.ArrayList(Value),

    pub fn deinit(self: *Yaml) void {
        self.arena.deinit();
    }

    pub fn load(allocator: *Allocator, source: []const u8) !Yaml {
        var arena = ArenaAllocator.init(allocator);

        var tree = Tree.init(&arena.allocator);
        try tree.parse(source);

        var docs = std.ArrayList(Value).init(&arena.allocator);
        try docs.ensureUnusedCapacity(tree.docs.items.len);

        for (tree.docs.items) |node| {
            const value = try Value.fromNode(&arena.allocator, &tree, node, null);
            docs.appendAssumeCapacity(value);
        }

        return Yaml{
            .arena = arena,
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
        OutOfMemory,
    };

    pub fn parse(self: *Yaml, comptime T: type) Error!T {
        if (self.docs.items.len == 0) return error.EmptyYaml;
        if (self.docs.items.len > 1) return error.MultiDocUnsupported;

        const doc = self.docs.items[0];
        return switch (@typeInfo(T)) {
            .Struct => self.parseStruct(T, doc.map),
            .Array => self.parseArray(T, doc.list),
            .Pointer => self.parsePointer(T, doc),
            .Void => unreachable,
            else => @compileError("unimplemented for " ++ @typeName(T)),
        };
    }

    fn parseStruct(self: *Yaml, comptime T: type, map: Map) Error!T {
        const struct_info = @typeInfo(T).Struct;
        var parsed: T = undefined;

        inline for (struct_info.fields) |field| {
            const value = map.get(field.name) orelse blk: {
                const field_name = try mem.replaceOwned(u8, &self.arena.allocator, field.name, "_", "-");
                break :blk map.get(field_name) orelse return error.StructFieldMissing;
            };

            @field(parsed, field.name) = switch (@typeInfo(field.field_type)) {
                .Int => try math.cast(field.field_type, value.int),
                .Float => math.lossyCast(field.field_type, value.float),
                .Pointer => try self.parsePointer(field.field_type, value),
                .Array => try self.parseArray(field.field_type, value.list),
                .Struct => try self.parseStruct(field.field_type, value.map),
                else => @compileError("unimplemented for " ++ @typeName(field.field_type)),
            };
        }

        return parsed;
    }

    fn parsePointer(self: *Yaml, comptime T: type, value: Value) Error!T {
        const ptr_info = @typeInfo(T).Pointer;
        const arena = &self.arena.allocator;

        switch (ptr_info.size) {
            .One => @compileError("unimplemented for pointer to " ++ @typeName(ptr_info.child)),
            .Slice => {
                const child_info = @typeInfo(ptr_info.child);
                if (child_info == .Int and child_info.Int.bits == 8) {
                    return value.string;
                }

                var parsed = try arena.alloc(ptr_info.child, value.list.len);
                for (value.list) |elem, i| {
                    parsed[i] = switch (child_info) {
                        .Int => try math.cast(ptr_info.child, elem.int),
                        .Float => math.lossyCast(ptr_info.child, elem.float),
                        .Pointer => try self.parsePointer(ptr_info.child, elem),
                        .Struct => try self.parseStruct(ptr_info.child, elem.map),
                        .Array => try self.parseArray(ptr_info.child, elem.list),
                        else => @compileError("unimplemented for " ++ @typeName(ptr_info.child)),
                    };
                }
                return parsed;
            },
            else => @compileError("unimplemented for pointer to many " ++ @typeName(ptr_info.child)),
        }
    }

    fn parseArray(self: *Yaml, comptime T: type, list: List) Error!T {
        const array_info = @typeInfo(T).Array;
        if (array_info.len != list.len) return error.ArraySizeMismatch;

        var parsed: T = undefined;
        for (list) |elem, i| {
            parsed[i] = switch (@typeInfo(array_info.child)) {
                .Int => try math.cast(array_info.child, elem.int),
                .Float => math.lossyCast(array_info.child, elem.float),
                .Pointer => try self.parsePointer(array_info.child, elem),
                .Struct => try self.parseStruct(array_info.child, elem.map),
                .Array => try self.parseArray(array_info.child, elem.list),
                else => @compileError("unimplemented for " ++ @typeName(array_info.child)),
            };
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

test "single quoted string" {
    const source =
        \\- 'hello'
        \\- 'here''s an escaped quote'
        \\- 'newlines and tabs\nare not\tsupported'
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const arr = try yaml.parse([3][]const u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expect(mem.eql(u8, arr[0], "hello"));
    try testing.expect(mem.eql(u8, arr[1], "here's an escaped quote"));
    try testing.expect(mem.eql(u8, arr[2], "newlines and tabs\\nare not\\tsupported"));
}

test "double quoted string" {
    const source =
        \\- "hello"
        \\- "\"here\" are some escaped quotes"
        \\- "newlines and tabs\nare\tsupported"
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const arr = try yaml.parse([3][]const u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expect(mem.eql(u8, arr[0], "hello"));
    try testing.expect(mem.eql(u8, arr[1],
        \\"here" are some escaped quotes
    ));
    try testing.expect(mem.eql(u8, arr[2],
        \\newlines and tabs
        \\are	supported
    ));
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
