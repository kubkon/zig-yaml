const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const Allocator = mem.Allocator;
const Token = @import("Tokenizer.zig").Token;
const Tree = @This();

source: []const u8,
tokens: std.MultiArrayList(TokenWithLineCol).Slice,
docs: []const Node.Index,
nodes: std.MultiArrayList(Node).Slice,
extra: []const u32,
string_bytes: []const u8,

pub fn deinit(self: *Tree, gpa: Allocator) void {
    self.tokens.deinit(gpa);
    self.nodes.deinit(gpa);
    gpa.free(self.docs);
    gpa.free(self.extra);
    gpa.free(self.string_bytes);
    self.* = undefined;
}

pub fn nodeTag(tree: Tree, node: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[@intFromEnum(node)];
}

pub fn nodeData(tree: Tree, node: Node.Index) Node.Data {
    return tree.nodes.items(.data)[@intFromEnum(node)];
}

pub fn nodeScope(tree: Tree, node: Node.Index) Node.Scope {
    return tree.nodes.items(.scope)[@intFromEnum(node)];
}

/// Returns the requested data, as well as the new index which is at the start of the
/// trailers for the object.
pub fn extraData(tree: Tree, comptime T: type, index: Extra) struct { data: T, end: Extra } {
    const fields = std.meta.fields(T);
    var i = @intFromEnum(index);
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => tree.extra[i],
            i32 => @bitCast(tree.extra[i]),
            Node.Index, Node.OptionalIndex, Token.Index => @enumFromInt(tree.extra[i]),
            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = @enumFromInt(i),
    };
}

/// Returns the directive metadata if present.
pub fn directive(self: Tree, node_index: Node.Index) ?[]const u8 {
    const tag = self.nodeTag(node_index);
    switch (tag) {
        .doc => return null,
        .doc_with_directive => {
            const data = self.nodeData(node_index).doc_with_directive;
            return self.rawString(data.directive, data.directive);
        },
        else => unreachable,
    }
}

/// Returns the raw string such that it matches the range [start, end) in the Token stream.
pub fn rawString(self: Tree, start: Token.Index, end: Token.Index) []const u8 {
    const start_token = self.token(start);
    const end_token = self.token(end);
    return self.source[start_token.loc.start..end_token.loc.end];
}

pub fn token(self: Tree, index: Token.Index) Token {
    return self.tokens.items(.token)[@intFromEnum(index)];
}

pub const Node = struct {
    tag: Tag,
    scope: Scope,
    data: Data,

    pub const Tag = enum(u8) {
        /// Document with no extra metadata.
        /// Comprises an index into another Node.
        /// Payload is maybe_value.
        doc,

        /// Document with directive.
        /// Payload is doc_with_directive.
        doc_with_directive,

        /// Map with a single key-value pair.
        /// Payload is map.
        map_single,

        /// Map with more than one key-value pair.
        /// Comprises an index into extras where payload is Map.
        /// Payload is extra.
        map_many,

        /// Empty list.
        /// Payload is unused.
        list_empty,

        /// List with one element.
        /// Payload is value.
        list_one,

        /// List with two elements.
        /// Payload is list.
        list_two,

        /// List of more than 2 elements.
        /// Comprises an index into extras where payload is List.
        /// Payload is extra.
        list_many,

        /// String that didn't require any preprocessing.
        /// Value is encoded directly as scope.
        /// Payload is unused.
        value,

        /// String that required preprocessing such as a quoted string.
        /// Payload is string.
        string_value,
    };

    /// Describes the Token range that encapsulates this Node.
    pub const Scope = struct {
        start: Token.Index,
        end: Token.Index,

        pub fn rawString(scope: Scope, tree: Tree) []const u8 {
            return tree.rawString(scope.start, scope.end);
        }
    };

    pub const Data = union {
        /// Node index.
        node: Index,

        /// Optional Node index.
        maybe_node: OptionalIndex,

        /// Document with a directive metadata.
        doc_with_directive: struct {
            maybe_node: OptionalIndex,
            directive: Token.Index,
        },

        /// Map with exactly one key-value pair.
        map: struct {
            key: Token.Index,
            maybe_node: OptionalIndex,
        },

        /// List with exactly two elements.
        list: struct {
            el1: Index,
            el2: Index,
        },

        /// Index and length into the string table.
        string: String,

        /// Index into extra array.
        extra: Extra,
    };

    pub const Index = enum(u32) {
        _,

        pub fn toOptional(ind: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(ind));
            assert(result != .none);
            return result;
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(opt: OptionalIndex) ?Index {
            if (opt == .none) return null;
            return @enumFromInt(@intFromEnum(opt));
        }
    };

    // Make sure we don't accidentally make nodes bigger than expected.
    // Note that in safety builds, Zig is allowed to insert a secret field for safety checks.
    comptime {
        if (!std.debug.runtime_safety) {
            assert(@sizeOf(Data) == 8);
        }
    }
};

/// Index into extra array.
pub const Extra = enum(u32) {
    _,
};

/// Trailing is a list of MapEntries.
pub const Map = struct {
    map_len: u32,

    pub const Entry = struct {
        key: Token.Index,
        maybe_node: Node.OptionalIndex,
    };
};

/// Trailing is a list of Node indexes.
pub const List = struct {
    list_len: u32,

    pub const Entry = struct {
        node: Node.Index,
    };
};

/// Index and length into string table.
pub const String = struct {
    index: Index,
    len: u32,

    pub const Index = enum(u32) {
        _,
    };

    pub fn slice(str: String, tree: Tree) []const u8 {
        return tree.string_bytes[@intFromEnum(str.index)..][0..str.len];
    }
};

/// Tracked line-column information for each Token.
pub const LineCol = struct {
    line: usize,
    col: usize,
};

/// Token with line-column information.
pub const TokenWithLineCol = struct {
    token: Token,
    line_col: LineCol,
};

test {
    std.testing.refAllDecls(@This());
}
