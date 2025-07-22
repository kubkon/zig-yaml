const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const log = std.log.scoped(.yaml);

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ErrorBundle = std.zig.ErrorBundle;
const Node = Tree.Node;
const Parser = @import("Parser.zig");
const ParseError = Parser.ParseError;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Tree = @import("Tree.zig");
const Yaml = @This();

source: []const u8,
docs: std.ArrayListUnmanaged(Value) = .empty,
tree: ?Tree = null,
parse_errors: ErrorBundle = .empty,

pub fn deinit(self: *Yaml, gpa: Allocator) void {
    for (self.docs.items) |*value| {
        value.deinit(gpa);
    }
    self.docs.deinit(gpa);
    if (self.tree) |*tree| {
        tree.deinit(gpa);
    }
    self.parse_errors.deinit(gpa);
    self.* = undefined;
}

pub fn load(self: *Yaml, gpa: Allocator) !void {
    var parser = try Parser.init(gpa, self.source);
    defer parser.deinit(gpa);

    parser.parse(gpa) catch |err| switch (err) {
        error.ParseFailure => {
            self.parse_errors = try parser.errors.toOwnedBundle("");
            return error.ParseFailure;
        },
        else => return err,
    };

    self.tree = try parser.toOwnedTree(gpa);

    try self.docs.ensureTotalCapacityPrecise(gpa, self.tree.?.docs.len);

    for (self.tree.?.docs) |node| {
        const value = try Value.fromNode(gpa, self.tree.?, node);
        self.docs.appendAssumeCapacity(value);
    }
}

pub fn parse(self: Yaml, arena: Allocator, comptime T: type) Error!T {
    if (self.docs.items.len == 0) {
        if (@typeInfo(T) == .void) return {};
        return error.TypeMismatch;
    }

    if (self.docs.items.len == 1) {
        return self.parseValue(arena, T, self.docs.items[0]);
    }

    switch (@typeInfo(T)) {
        .array => |info| {
            var parsed: T = undefined;
            for (self.docs.items, 0..) |doc, i| {
                parsed[i] = try self.parseValue(arena, info.child, doc);
            }
            return parsed;
        },
        .pointer => |info| {
            switch (info.size) {
                .slice => {
                    var parsed = try arena.alloc(info.child, self.docs.items.len);
                    for (self.docs.items, 0..) |doc, i| {
                        parsed[i] = try self.parseValue(arena, info.child, doc);
                    }
                    return parsed;
                },
                else => return error.TypeMismatch,
            }
        },
        .@"union" => return error.Unimplemented,
        else => return error.TypeMismatch,
    }
}

fn parseValue(self: Yaml, arena: Allocator, comptime T: type, value: Value) Error!T {
    return switch (@typeInfo(T)) {
        .int => self.parseInt(T, value),
        .bool => self.parseBoolean(bool, value),
        .float => self.parseFloat(T, value),
        .@"struct" => if (value.asMap()) |map| {
            return self.parseStruct(arena, T, map);
        } else return error.TypeMismatch,
        .@"union" => self.parseUnion(arena, T, value),
        .array => if (value.asList()) |list| {
            return self.parseArray(arena, T, list);
        } else return error.TypeMismatch,
        .pointer => if (value.asList()) |list| {
            return self.parsePointer(arena, T, .{ .list = list });
        } else if (value.asScalar()) |scalar| {
            return self.parsePointer(arena, T, .{ .scalar = try arena.dupe(u8, scalar) });
        } else if (value.asMap()) |map| {
            return self.parsePointer(arena, T, .{ .map = map });
        } else return error.TypeMismatch,
        .@"enum" => self.parseEnum(T, value),
        .void => error.TypeMismatch,
        .optional => unreachable,
        else => error.Unimplemented,
    };
}

fn parseInt(self: Yaml, comptime T: type, value: Value) Error!T {
    _ = self;
    const scalar = value.asScalar() orelse return error.TypeMismatch;
    return try std.fmt.parseInt(T, scalar, 0);
}

fn parseFloat(self: Yaml, comptime T: type, value: Value) Error!T {
    _ = self;
    const scalar = value.asScalar() orelse return error.TypeMismatch;
    return try std.fmt.parseFloat(T, scalar);
}

fn parseBoolean(self: Yaml, comptime T: type, value: Value) Error!T {
    _ = self;
    const raw = value.asScalar() orelse return error.TypeMismatch;

    if (raw.len > 0 and raw.len <= longestBooleanValueString) {
        var buffer: [longestBooleanValueString]u8 = undefined;
        const lower_raw = std.ascii.lowerString(&buffer, raw);

        for (supportedTruthyBooleanValue) |v| {
            if (std.mem.eql(u8, v, lower_raw)) {
                return true;
            }
        }

        for (supportedFalsyBooleanValue) |v| {
            if (std.mem.eql(u8, v, lower_raw)) {
                return false;
            }
        }
    }

    return error.TypeMismatch;
}

fn parseUnion(self: Yaml, arena: Allocator, comptime T: type, value: Value) Error!T {
    const union_info = @typeInfo(T).@"union";

    if (union_info.tag_type) |_| {
        inline for (union_info.fields) |field| {
            if (self.parseValue(arena, field.type, value)) |u_value| {
                return @unionInit(T, field.name, u_value);
            } else |err| switch (err) {
                error.InvalidCharacter => {},
                error.TypeMismatch => {},
                error.StructFieldMissing => {},
                else => return err,
            }
        }
    } else return error.UntaggedUnion;

    return error.UnionTagMissing;
}

fn parseOptional(self: Yaml, arena: Allocator, comptime T: type, value: ?Value) Error!T {
    const unwrapped = value orelse return null;
    const opt_info = @typeInfo(T).optional;
    return @as(T, try self.parseValue(arena, opt_info.child, unwrapped));
}

fn parseStruct(self: Yaml, arena: Allocator, comptime T: type, map: Map) Error!T {
    const struct_info = @typeInfo(T).@"struct";
    var parsed: T = undefined;

    inline for (struct_info.fields) |field| {
        var value: ?Value = map.get(field.name) orelse blk: {
            const field_name = try mem.replaceOwned(u8, arena, field.name, "_", "-");
            break :blk map.get(field_name);
        };

        if (@typeInfo(field.type) == .optional) {
            if (value == null) blk: {
                const maybe_default_value = field.defaultValue() orelse break :blk;
                value = Value.encode(arena, maybe_default_value) catch break :blk;
            }
            @field(parsed, field.name) = try self.parseOptional(arena, field.type, value);
            continue;
        }

        if (field.defaultValue()) |default_value| {
            if (value == null) blk: {
                value = Value.encode(arena, default_value) catch break :blk;
            }
        }

        const unwrapped = value orelse {
            log.debug("missing struct field: {s}: {s}", .{ field.name, @typeName(field.type) });
            return error.StructFieldMissing;
        };
        @field(parsed, field.name) = try self.parseValue(arena, field.type, unwrapped);
    }

    return parsed;
}

fn parsePointer(self: Yaml, arena: Allocator, comptime T: type, value: Value) Error!T {
    const ptr_info = @typeInfo(T).pointer;

    switch (ptr_info.size) {
        .slice => {
            if (ptr_info.child == u8) {
                const scalar = value.asScalar() orelse return error.TypeMismatch;
                return try arena.dupe(u8, scalar);
            }

            if (value.asList()) |list| {
                var parsed = try arena.alloc(ptr_info.child, list.len);
                for (list, 0..) |elem, i| {
                    parsed[i] = try self.parseValue(arena, ptr_info.child, elem);
                }
                return parsed;
            }

            return error.TypeMismatch;
        },
        .one => {
            const parsed = try arena.create(ptr_info.child);
            parsed.* = try self.parseValue(arena, ptr_info.child, value);
            return parsed;
        },
        else => return error.Unimplemented,
    }
}

fn parseArray(self: Yaml, arena: Allocator, comptime T: type, list: List) Error!T {
    const array_info = @typeInfo(T).array;
    if (array_info.len != list.len) return error.ArraySizeMismatch;

    var parsed: T = undefined;
    for (list, 0..) |elem, i| {
        parsed[i] = try self.parseValue(arena, array_info.child, elem);
    }

    return parsed;
}

fn parseEnum(self: Yaml, comptime T: type, value: Value) Error!T {
    _ = self;

    const scalar = value.asScalar() orelse return error.TypeMismatch;
    return std.meta.stringToEnum(T, scalar) orelse error.InvalidEnum;
}

pub fn stringify(self: Yaml, writer: *std.Io.Writer) !void {
    for (self.docs.items, self.tree.?.docs) |doc, node| {
        try writer.writeAll("---");
        if (self.tree.?.directive(node)) |directive| {
            try writer.print(" !{s}", .{directive});
        }
        try writer.writeByte('\n');
        try doc.stringify(writer, .{});
        try writer.writeByte('\n');
    }
    try writer.writeAll("...\n");
}

const supportedTruthyBooleanValue: [4][]const u8 = .{ "y", "yes", "on", "true" };
const supportedFalsyBooleanValue: [4][]const u8 = .{ "n", "no", "off", "false" };

const longestBooleanValueString = blk: {
    var lengths: [supportedTruthyBooleanValue.len + supportedFalsyBooleanValue.len]usize = undefined;
    for (supportedTruthyBooleanValue, 0..) |v, i| {
        lengths[i] = v.len;
    }
    for (supportedFalsyBooleanValue, supportedTruthyBooleanValue.len..) |v, i| {
        lengths[i] = v.len;
    }
    break :blk mem.max(usize, &lengths);
};

pub const Error = error{
    InvalidCharacter,
    Unimplemented,
    TypeMismatch,
    StructFieldMissing,
    ArraySizeMismatch,
    UntaggedUnion,
    UnionTagMissing,
    Overflow,
    OutOfMemory,
    InvalidEnum,
};

pub const YamlError = error{
    UnexpectedNodeType,
    DuplicateMapKey,
    OutOfMemory,
    CannotEncodeValue,
} || ParseError || std.fmt.ParseIntError;

pub const StringifyError = error{
    OutOfMemory,
} || YamlError || std.fs.File.WriteError || std.Io.Writer.Error;

pub const List = []Value;
pub const Map = std.StringArrayHashMapUnmanaged(Value);

pub const Value = union(enum) {
    empty,
    scalar: []const u8,
    list: List,
    map: Map,
    boolean: bool,

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .scalar => |scalar| gpa.free(scalar),
            .list => |list| {
                for (list) |*value| {
                    value.deinit(gpa);
                }
                gpa.free(list);
            },
            .map => |*map| {
                for (map.keys(), map.values()) |key, *value| {
                    gpa.free(key);
                    value.deinit(gpa);
                }
                map.deinit(gpa);
            },
            .empty, .boolean => {},
        }
    }

    pub fn asScalar(self: Value) ?[]const u8 {
        if (self != .scalar) return null;
        return self.scalar;
    }

    pub fn asList(self: Value) ?List {
        if (self != .list) return null;
        return self.list;
    }

    pub fn asMap(self: Value) ?Map {
        if (self != .map) return null;
        return self.map;
    }

    const StringifyArgs = struct {
        indentation: usize = 0,
        should_inline_first_key: bool = false,
    };

    pub fn stringify(self: Value, writer: *std.Io.Writer, args: StringifyArgs) StringifyError!void {
        switch (self) {
            .empty => return,
            .scalar => |scalar| return writer.print("{s}", .{scalar}),
            .list => |list| {
                const len = list.len;
                if (len == 0) return;

                const first = list[0];
                if (first.isCompound()) {
                    for (list, 0..) |elem, i| {
                        const indentation = try writer.writableSlice(args.indentation);
                        @memset(indentation, ' ');
                        try writer.writeAll("- ");
                        try elem.stringify(writer, .{
                            .indentation = args.indentation + 2,
                            .should_inline_first_key = true,
                        });
                        if (i < len - 1) {
                            try writer.writeByte('\n');
                        }
                    }
                    return;
                }

                try writer.writeAll("[ ");
                for (list, 0..) |elem, i| {
                    try elem.stringify(writer, args);
                    if (i < len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(" ]");
            },
            .map => |map| {
                const len = map.count();
                if (len == 0) return;

                var i: usize = 0;
                for (map.keys(), map.values()) |key, value| {
                    if (!args.should_inline_first_key or i != 0) {
                        const indentation = try writer.writableSlice(args.indentation);
                        @memset(indentation, ' ');
                    }
                    try writer.print("{s}: ", .{key});

                    const should_inline = blk: {
                        if (!value.isCompound()) break :blk true;
                        if (value == .list and value.list.len > 0 and !value.list[0].isCompound()) break :blk true;
                        break :blk false;
                    };

                    if (should_inline) {
                        try value.stringify(writer, args);
                    } else {
                        try writer.writeByte('\n');
                        try value.stringify(writer, .{
                            .indentation = args.indentation + 4,
                        });
                    }

                    if (i < len - 1) {
                        try writer.writeByte('\n');
                    }

                    i += 1;
                }
            },
            .boolean => |value| return writer.writeAll(if (value) "true" else "false"),
        }
    }

    fn isCompound(self: Value) bool {
        return switch (self) {
            .list, .map => true,
            else => false,
        };
    }

    fn fromNode(gpa: Allocator, tree: Tree, node_index: Node.Index) YamlError!Value {
        const tag = tree.nodeTag(node_index);
        switch (tag) {
            .doc => {
                const inner = tree.nodeData(node_index).maybe_node.unwrap() orelse return .empty;
                return Value.fromNode(gpa, tree, inner);
            },
            .doc_with_directive => {
                const inner = tree.nodeData(node_index).doc_with_directive.maybe_node.unwrap() orelse return .empty;
                return Value.fromNode(gpa, tree, inner);
            },
            .map_single => {
                const entry = tree.nodeData(node_index).map;

                // TODO use ContextAdapted HashMap and do not duplicate keys, intern
                // in a contiguous string buffer.
                var out_map: Map = .empty;
                errdefer out_map.deinit(gpa);
                try out_map.ensureTotalCapacity(gpa, 1);

                const key = try gpa.dupe(u8, tree.rawString(entry.key, entry.key));
                errdefer gpa.free(key);

                const gop = out_map.getOrPutAssumeCapacity(key);
                if (gop.found_existing) return error.DuplicateMapKey;

                gop.value_ptr.* = if (entry.maybe_node.unwrap()) |value|
                    try Value.fromNode(gpa, tree, value)
                else
                    .empty;

                return Value{ .map = out_map };
            },
            .map_many => {
                const extra_index = tree.nodeData(node_index).extra;
                const map = tree.extraData(Tree.Map, extra_index);

                // TODO use ContextAdapted HashMap and do not duplicate keys, intern
                // in a contiguous string buffer.
                var out_map: Map = .empty;
                errdefer {
                    for (out_map.keys(), out_map.values()) |key, *value| {
                        gpa.free(key);
                        value.deinit(gpa);
                    }
                    out_map.deinit(gpa);
                }
                try out_map.ensureTotalCapacity(gpa, map.data.map_len);

                var extra_end = map.end;
                for (0..map.data.map_len) |_| {
                    const entry = tree.extraData(Tree.Map.Entry, extra_end);
                    extra_end = entry.end;

                    const key = try gpa.dupe(u8, tree.rawString(entry.data.key, entry.data.key));
                    errdefer gpa.free(key);

                    const gop = out_map.getOrPutAssumeCapacity(key);
                    if (gop.found_existing) return error.DuplicateMapKey;

                    gop.value_ptr.* = if (entry.data.maybe_node.unwrap()) |value|
                        try Value.fromNode(gpa, tree, value)
                    else
                        .empty;
                }

                return Value{ .map = out_map };
            },
            .list_empty => {
                return Value{ .list = &.{} };
            },
            .list_one => {
                const value_index = tree.nodeData(node_index).node;
                const out_list = try gpa.alloc(Value, 1);
                errdefer gpa.free(out_list);
                const value = try Value.fromNode(gpa, tree, value_index);
                out_list[0] = value;
                return Value{ .list = out_list };
            },
            .list_two => {
                const list = tree.nodeData(node_index).list;
                const out_list = try gpa.alloc(Value, 2);
                errdefer {
                    for (out_list) |*value| {
                        value.deinit(gpa);
                    }
                    gpa.free(out_list);
                }
                for (out_list, &[2]Node.Index{ list.el1, list.el2 }) |*out, value_index| {
                    out.* = try Value.fromNode(gpa, tree, value_index);
                }
                return Value{ .list = out_list };
            },
            .list_many => {
                const extra_index = tree.nodeData(node_index).extra;
                const list = tree.extraData(Tree.List, extra_index);

                var out_list: std.ArrayListUnmanaged(Value) = .empty;
                errdefer for (out_list.items) |*value| {
                    value.deinit(gpa);
                };
                defer out_list.deinit(gpa);
                try out_list.ensureTotalCapacityPrecise(gpa, list.data.list_len);

                var extra_end = list.end;
                for (0..list.data.list_len) |_| {
                    const elem = tree.extraData(Tree.List.Entry, extra_end);
                    extra_end = elem.end;

                    const value = try Value.fromNode(gpa, tree, elem.data.node);
                    out_list.appendAssumeCapacity(value);
                }

                return Value{ .list = try out_list.toOwnedSlice(gpa) };
            },
            .string_value => {
                const raw = tree.nodeData(node_index).string.slice(tree);
                return Value{ .scalar = try gpa.dupe(u8, raw) };
            },
            .value => {
                const raw = tree.nodeScope(node_index).rawString(tree);
                return Value{ .scalar = try gpa.dupe(u8, raw) };
            },
        }
    }

    pub fn encode(arena: Allocator, input: anytype) YamlError!?Value {
        switch (@typeInfo(@TypeOf(input))) {
            .comptime_int,
            .int,
            .comptime_float,
            .float,
            => return Value{ .scalar = try std.fmt.allocPrint(arena, "{d}", .{input}) },

            .@"struct" => |info| if (info.is_tuple) {
                var list: std.ArrayListUnmanaged(Value) = .empty;
                try list.ensureTotalCapacityPrecise(arena, info.fields.len);

                inline for (info.fields) |field| {
                    if (try encode(arena, @field(input, field.name))) |value| {
                        list.appendAssumeCapacity(value);
                    }
                }

                return Value{ .list = try list.toOwnedSlice(arena) };
            } else {
                var map: Map = .empty;
                try map.ensureTotalCapacity(arena, info.fields.len);

                inline for (info.fields) |field| {
                    if (try encode(arena, @field(input, field.name))) |value| {
                        const key = try arena.dupe(u8, field.name);
                        map.putAssumeCapacityNoClobber(key, value);
                    }
                }

                return Value{ .map = map };
            },

            .@"union" => |info| if (info.tag_type) |tag_type| {
                inline for (info.fields) |field| {
                    if (@field(tag_type, field.name) == input) {
                        return try encode(arena, @field(input, field.name));
                    }
                } else unreachable;
            } else return error.UntaggedUnion,

            .array => return encode(arena, &input),

            .pointer => |info| switch (info.size) {
                .one => switch (@typeInfo(info.child)) {
                    .array => |child_info| {
                        const Slice = []const child_info.child;
                        return encode(arena, @as(Slice, input));
                    },
                    else => {
                        return encode(arena, input);
                    },
                },
                .slice => {
                    if (info.child == u8) {
                        return Value{ .scalar = try arena.dupe(u8, input) };
                    }

                    var list: std.ArrayListUnmanaged(Value) = .empty;
                    try list.ensureTotalCapacityPrecise(arena, input.len);

                    for (input) |elem| {
                        if (try encode(arena, elem)) |value| {
                            list.appendAssumeCapacity(value);
                        } else {
                            log.debug("Could not encode value in a list: {any}", .{elem});
                            return error.CannotEncodeValue;
                        }
                    }

                    return Value{ .list = try list.toOwnedSlice(arena) };
                },
                else => {
                    @compileError("Unhandled type: " ++ @typeName(@TypeOf(input)));
                },
            },

            // TODO we should probably have an option to encode `null` and also
            // allow for some default value too.
            .optional => return if (input) |val| encode(arena, val) else null,

            .null => return null,
            .bool => return Value{ .boolean = input },
            .@"enum" => return Value{ .scalar = try arena.dupe(u8, @tagName(input)) },

            else => {
                @compileError("Unhandled type: " ++ @typeName(@TypeOf(input)));
            },
        }
    }
};

pub const ErrorMsg = struct {
    msg: []const u8,
    line_col: Tree.LineCol,

    pub fn deinit(err: *ErrorMsg, gpa: Allocator) void {
        gpa.free(err.msg);
    }
};

test {
    _ = @import("Yaml/test.zig");
}
