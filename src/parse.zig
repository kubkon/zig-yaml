const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.parse);
const mem = std.mem;

const Allocator = mem.Allocator;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const TokenIterator = Tokenizer.TokenIterator;

pub const Node = struct {
    tag: Tag,
    scope: Scope,
    data: Data,

    pub const Tag = enum(u8) {
        /// Comprises an index into another Node.
        /// Payload is maybe_value.
        doc,

        /// Doc with directive.
        /// Payload is doc_with_directive.
        doc_with_directive,

        /// Map with a single key-value pair.
        /// Payload is map.
        map_single,

        /// Comprises an index into extras where payload is Map.
        /// Payload is extra.
        map_many,

        /// Empty list has no payload.
        list_empty,

        /// List with one element.
        /// Payload is value.
        list_one,

        /// List with two elements.
        /// Payload is list.
        list_two,

        /// Comprises an index into extras where payload is List.
        /// Payload is extra.
        list_many,

        /// String that didn't require any processing.
        /// Value is encoded directly as scope.
        /// Payload is unused.
        value,

        /// Payload is string.
        string_value,
    };

    pub const Scope = struct {
        start: Token.Index,
        end: Token.Index,
    };

    pub const Data = union {
        node: Index,

        maybe_node: OptionalIndex,

        doc_with_directive: struct {
            maybe_node: OptionalIndex,
            directive: Token.Index,
        },

        map: struct {
            key: Token.Index,
            maybe_node: OptionalIndex,
        },

        list: struct {
            el1: Index,
            el2: Index,
        },

        string: String,

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

/// Index and length into string_bytes.
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

pub const ParseError = error{
    InvalidEscapeSequence,
    MalformedYaml,
    NestedDocuments,
    UnexpectedEof,
    UnexpectedToken,
    Unhandled,
} || Allocator.Error;

pub const LineCol = struct {
    line: usize,
    col: usize,
};

pub const TokenWithLineCol = struct {
    token: Token,
    line_col: LineCol,
};

pub const Tree = struct {
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

    pub fn getDirective(self: Tree, node_index: Node.Index) ?[]const u8 {
        const tag = self.nodeTag(node_index);
        switch (tag) {
            .doc => return null,
            .doc_with_directive => {
                const data = self.nodeData(node_index).doc_with_directive;
                return self.getRaw(data.directive, data.directive);
            },
            else => unreachable,
        }
    }

    pub fn getRaw(self: Tree, start: Token.Index, end: Token.Index) []const u8 {
        const start_token = self.getToken(start);
        const end_token = self.getToken(end);
        return self.source[start_token.loc.start..end_token.loc.end];
    }

    pub fn getToken(self: Tree, index: Token.Index) Token {
        return self.tokens.items(.token)[@intFromEnum(index)];
    }
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(TokenWithLineCol) = .{},
    token_it: TokenIterator = undefined,
    docs: std.ArrayListUnmanaged(Node.Index) = .empty,
    nodes: std.MultiArrayList(Node) = .empty,
    extra: std.ArrayListUnmanaged(u32) = .empty,
    string_bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Parser) void {
        const gpa = self.allocator;
        self.tokens.deinit(gpa);
        self.docs.deinit(gpa);
        self.nodes.deinit(gpa);
        self.extra.deinit(gpa);
        self.string_bytes.deinit(gpa);
        self.* = undefined;
    }

    pub fn parse(self: *Parser) ParseError!void {
        const gpa = self.allocator;

        var tokenizer = Tokenizer{ .buffer = self.source };
        var line: usize = 0;
        var prev_line_last_col: usize = 0;

        while (true) {
            const token = tokenizer.next();
            const token_index = try self.tokens.addOne(gpa);

            self.tokens.set(token_index, .{
                .token = token,
                .line_col = .{
                    .line = line,
                    .col = token.loc.start - prev_line_last_col,
                },
            });

            switch (token.id) {
                .eof => break,
                .new_line => {
                    line += 1;
                    prev_line_last_col = token.loc.end;
                },
                else => {},
            }
        }

        self.token_it = .{ .buffer = self.tokens.items(.token) };

        self.eatCommentsAndSpace(&.{});

        while (true) {
            self.eatCommentsAndSpace(&.{});
            const token = self.token_it.next() orelse break;

            log.debug("(main) next {s}@{d}", .{ @tagName(token.id), @intFromEnum(self.token_it.pos) - 1 });

            switch (token.id) {
                .eof => break,
                else => {
                    self.token_it.seekBy(-1);
                    const node_index = try self.doc();
                    try self.docs.append(gpa, node_index);
                },
            }
        }
    }

    pub fn toOwnedTree(self: *Parser) Allocator.Error!Tree {
        const gpa = self.allocator;
        return .{
            .source = self.source,
            .tokens = self.tokens.toOwnedSlice(),
            .docs = try self.docs.toOwnedSlice(gpa),
            .nodes = self.nodes.toOwnedSlice(),
            .extra = try self.extra.toOwnedSlice(gpa),
            .string_bytes = try self.string_bytes.toOwnedSlice(gpa),
        };
    }

    fn addString(self: *Parser, string: []const u8) Allocator.Error!String {
        const gpa = self.allocator;
        const index: u32 = @intCast(self.string_bytes.items.len);
        try self.string_bytes.ensureUnusedCapacity(gpa, string.len);
        self.string_bytes.appendSliceAssumeCapacity(string);
        return .{ .index = @enumFromInt(index), .len = @intCast(string.len) };
    }

    fn addExtra(self: *Parser, extra: anytype) Allocator.Error!u32 {
        const fields = std.meta.fields(@TypeOf(extra));
        try self.extra.ensureUnusedCapacity(self.gpa, fields.len);
        return self.addExtraAssumeCapacity(extra);
    }

    fn addExtraAssumeCapacity(self: *Parser, extra: anytype) u32 {
        const result: u32 = @intCast(self.extra.items.len);
        self.extra.appendSliceAssumeCapacity(&payloadToExtraItems(extra));
        return result;
    }

    fn payloadToExtraItems(data: anytype) [@typeInfo(@TypeOf(data)).@"struct".fields.len]u32 {
        const fields = @typeInfo(@TypeOf(data)).@"struct".fields;
        var result: [fields.len]u32 = undefined;
        inline for (&result, fields) |*val, field| {
            val.* = switch (field.type) {
                u32 => @field(data, field.name),
                i32 => @bitCast(@field(data, field.name)),
                Node.Index, Node.OptionalIndex, Token.Index => @intFromEnum(@field(data, field.name)),
                else => @compileError("bad field type: " ++ @typeName(field.type)),
            };
        }
        return result;
    }

    fn value(self: *Parser) ParseError!Node.OptionalIndex {
        self.eatCommentsAndSpace(&.{});

        const pos = self.token_it.pos;
        const token = self.token_it.next() orelse return error.UnexpectedEof;

        log.debug("  next {s}@{d}", .{ @tagName(token.id), pos });

        switch (token.id) {
            .literal => if (self.eatToken(.map_value_ind, &.{ .new_line, .comment })) |_| {
                // map
                self.token_it.seekTo(pos);
                return self.map();
            } else {
                // leaf value
                self.token_it.seekTo(pos);
                return self.leafValue();
            },
            .single_quoted, .double_quoted => {
                // leaf value
                self.token_it.seekBy(-1);
                return self.leafValue();
            },
            .seq_item_ind => {
                // list
                self.token_it.seekBy(-1);
                return self.list();
            },
            .flow_seq_start => {
                // list
                self.token_it.seekBy(-1);
                return self.listBracketed();
            },
            else => return .none,
        }
    }

    fn doc(self: *Parser) ParseError!Node.Index {
        const gpa = self.allocator;
        const node_index = try self.nodes.addOne(gpa);
        const node_start = self.token_it.pos;

        log.debug("(doc) begin {s}@{d}", .{ @tagName(self.getToken(node_start).id), node_start });

        // Parse header
        const header: union(enum) {
            directive: Token.Index,
            explicit,
            implicit,
        } = if (self.eatToken(.doc_start, &.{})) |doc_pos| explicit: {
            if (self.getCol(doc_pos) > 0) return error.MalformedYaml;
            if (self.eatToken(.tag, &.{ .new_line, .comment })) |_| {
                break :explicit .{ .directive = try self.expectToken(.literal, &.{ .new_line, .comment }) };
            }
            break :explicit .explicit;
        } else .implicit;
        const directive = switch (header) {
            .directive => |index| index,
            else => null,
        };
        const is_explicit = switch (header) {
            .directive, .explicit => true,
            .implicit => false,
        };

        // Parse value
        const value_index = try self.value();
        if (value_index == .none) {
            self.token_it.seekBy(-1);
        }

        // Parse footer
        const node_end: Token.Index = footer: {
            if (self.eatToken(.doc_end, &.{})) |pos| {
                if (!is_explicit) return error.UnexpectedToken;
                if (self.getCol(pos) > 0) return error.MalformedYaml;
                break :footer pos;
            }
            if (self.eatToken(.doc_start, &.{})) |pos| {
                if (!is_explicit) return error.UnexpectedToken;
                if (self.getCol(pos) > 0) return error.MalformedYaml;
                self.token_it.seekBy(-1);
                break :footer @enumFromInt(@intFromEnum(pos) - 1);
            }
            if (self.eatToken(.eof, &.{})) |pos| {
                break :footer @enumFromInt(@intFromEnum(pos) - 1);
            }
            return error.UnexpectedToken;
        };

        log.debug("(doc) end {s}@{d}", .{ @tagName(self.getToken(node_end).id), node_end });

        self.nodes.set(node_index, .{
            .tag = if (directive == null) .doc else .doc_with_directive,
            .scope = .{
                .start = node_start,
                .end = node_end,
            },
            .data = if (directive == null) .{
                .maybe_node = value_index,
            } else .{
                .doc_with_directive = .{
                    .maybe_node = value_index,
                    .directive = directive.?,
                },
            },
        });

        return @enumFromInt(node_index);
    }

    fn map(self: *Parser) ParseError!Node.OptionalIndex {
        const gpa = self.allocator;
        const node_index = try self.nodes.addOne(gpa);
        const node_start = self.token_it.pos;

        var entries: std.ArrayListUnmanaged(Map.Entry) = .empty;
        defer entries.deinit(gpa);

        log.debug("(map) begin {s}@{d}", .{ @tagName(self.getToken(node_start).id), node_start });

        const col = self.getCol(node_start);

        while (true) {
            self.eatCommentsAndSpace(&.{});

            // Parse key
            const key_pos = self.token_it.pos;
            if (self.getCol(key_pos) < col) break;

            const key = self.token_it.next() orelse return error.UnexpectedEof;
            switch (key.id) {
                .literal => {},
                .doc_start, .doc_end, .eof => {
                    self.token_it.seekBy(-1);
                    break;
                },
                .flow_map_end => {
                    break;
                },
                else => {
                    log.err("Unhandled token in map: {}", .{key});
                    // TODO key not being a literal
                    return error.Unhandled;
                },
            }

            log.debug("(map) key {s}@{d}", .{ self.getRaw(key_pos, key_pos), key_pos });

            // Separator
            _ = try self.expectToken(.map_value_ind, &.{ .new_line, .comment });

            // Parse value
            const value_index = try self.value();

            if (value_index.unwrap()) |v| {
                const value_start = self.nodes.items(.scope)[@intFromEnum(v)].start;
                if (self.getCol(value_start) < self.getCol(key_pos)) {
                    return error.MalformedYaml;
                }
                if (self.nodes.items(.tag)[@intFromEnum(v)] == .value) {
                    if (self.getCol(value_start) == self.getCol(key_pos)) {
                        return error.MalformedYaml;
                    }
                }
            }

            try entries.append(gpa, .{
                .key = key_pos,
                .maybe_node = value_index,
            });
        }

        const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);

        log.debug("(map) end {s}@{d}", .{ @tagName(self.getToken(node_end).id), node_end });

        const scope: Node.Scope = .{
            .start = node_start,
            .end = node_end,
        };

        if (entries.items.len == 1) {
            const entry = entries.items[0];

            self.nodes.set(node_index, .{
                .tag = .map_single,
                .scope = scope,
                .data = .{ .map = .{
                    .key = entry.key,
                    .maybe_node = entry.maybe_node,
                } },
            });
        } else {
            try self.extra.ensureUnusedCapacity(gpa, entries.items.len * 2 + 1);
            const extra_index: u32 = @intCast(self.extra.items.len);

            _ = self.addExtraAssumeCapacity(Map{ .map_len = @intCast(entries.items.len) });

            for (entries.items) |entry| {
                _ = self.addExtraAssumeCapacity(entry);
            }

            self.nodes.set(node_index, .{
                .tag = .map_many,
                .scope = scope,
                .data = .{ .extra = @enumFromInt(extra_index) },
            });
        }

        return @as(Node.Index, @enumFromInt(node_index)).toOptional();
    }

    fn list(self: *Parser) ParseError!Node.OptionalIndex {
        const gpa = self.allocator;
        const node_index: Node.Index = @enumFromInt(try self.nodes.addOne(gpa));
        const node_start = self.token_it.pos;

        var values: std.ArrayListUnmanaged(List.Entry) = .empty;
        defer values.deinit(gpa);

        const first_col = self.getCol(node_start);

        log.debug("(list) begin {s}@{d}", .{ @tagName(self.getToken(node_start).id), node_start });

        while (true) {
            self.eatCommentsAndSpace(&.{});

            const pos = self.eatToken(.seq_item_ind, &.{}) orelse {
                log.debug("(list {d}) break", .{first_col});
                break;
            };
            const cur_col = self.getCol(pos);
            if (cur_col < first_col) {
                log.debug("(list {d}) << break", .{first_col});
                // this hyphen belongs to an outer list
                self.token_it.seekBy(-1);
                // this will end this list
                break;
            }
            //  an inner list will be parsed by self.value() so
            //  checking for  cur_col > first_col is not necessary here

            const value_index = try self.value();
            if (value_index == .none) return error.MalformedYaml;

            try values.append(gpa, .{ .node = value_index.unwrap().? });
        }

        const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);

        log.debug("(list) end {s}@{d}", .{ @tagName(self.getToken(node_end).id), node_end });

        try self.encodeList(gpa, node_index, values.items, .{
            .start = node_start,
            .end = node_end,
        });

        return node_index.toOptional();
    }

    fn listBracketed(self: *Parser) ParseError!Node.OptionalIndex {
        const gpa = self.allocator;
        const node_index: Node.Index = @enumFromInt(try self.nodes.addOne(gpa));
        const node_start = self.token_it.pos;

        var values: std.ArrayListUnmanaged(List.Entry) = .empty;
        defer values.deinit(gpa);

        log.debug("(list) begin {s}@{d}", .{ @tagName(self.getToken(node_start).id), node_start });

        _ = try self.expectToken(.flow_seq_start, &.{});

        const node_end: Token.Index = while (true) {
            self.eatCommentsAndSpace(&.{.comment});

            if (self.eatToken(.flow_seq_end, &.{.comment})) |pos|
                break pos;

            _ = self.eatToken(.comma, &.{.comment});

            const value_index = try self.value();
            if (value_index == .none) return error.MalformedYaml;

            try values.append(gpa, .{ .node = value_index.unwrap().? });
        };

        log.debug("(list) end {s}@{d}", .{ @tagName(self.getToken(node_end).id), node_end });

        try self.encodeList(gpa, node_index, values.items, .{
            .start = node_start,
            .end = node_end,
        });

        return node_index.toOptional();
    }

    fn encodeList(
        self: *Parser,
        gpa: Allocator,
        node_index: Node.Index,
        values: []const List.Entry,
        node_scope: Node.Scope,
    ) Allocator.Error!void {
        const index = @intFromEnum(node_index);
        switch (values.len) {
            0 => {
                self.nodes.set(index, .{
                    .tag = .list_empty,
                    .scope = node_scope,
                    .data = undefined,
                });
            },
            1 => {
                self.nodes.set(index, .{
                    .tag = .list_one,
                    .scope = node_scope,
                    .data = .{ .node = values[0].node },
                });
            },
            2 => {
                self.nodes.set(index, .{
                    .tag = .list_two,
                    .scope = node_scope,
                    .data = .{ .list = .{
                        .el1 = values[0].node,
                        .el2 = values[1].node,
                    } },
                });
            },
            else => {
                try self.extra.ensureUnusedCapacity(gpa, values.len + 1);
                const extra_index: u32 = @intCast(self.extra.items.len);

                _ = self.addExtraAssumeCapacity(List{ .list_len = @intCast(values.len) });

                for (values) |entry| {
                    _ = self.addExtraAssumeCapacity(entry);
                }

                self.nodes.set(index, .{
                    .tag = .list_many,
                    .scope = node_scope,
                    .data = .{ .extra = @enumFromInt(extra_index) },
                });
            },
        }
    }

    fn leafValue(self: *Parser) ParseError!Node.OptionalIndex {
        const gpa = self.allocator;
        const node_index = try self.nodes.addOne(gpa);
        const node_start = self.token_it.pos;

        // TODO handle multiline strings in new block scope
        while (self.token_it.next()) |tok| {
            switch (tok.id) {
                .single_quoted => {
                    const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);
                    log.debug("(leaf) {s}", .{self.getRaw(node_start, node_end)});
                    const raw = self.getRaw(node_start, node_end);
                    assert(raw.len > 0);
                    const string = try self.parseSingleQuoted(raw);

                    self.nodes.set(node_index, .{
                        .tag = .string_value,
                        .scope = .{
                            .start = node_start,
                            .end = node_end,
                        },
                        .data = .{ .string = string },
                    });

                    return @as(Node.Index, @enumFromInt(node_index)).toOptional();
                },
                .double_quoted => {
                    const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);
                    log.debug("(leaf) {s}", .{self.getRaw(node_start, node_end)});
                    const raw = self.getRaw(node_start, node_end);
                    assert(raw.len > 0);
                    const string = try self.parseDoubleQuoted(raw);

                    self.nodes.set(node_index, .{
                        .tag = .string_value,
                        .scope = .{
                            .start = node_start,
                            .end = node_end,
                        },
                        .data = .{ .string = string },
                    });

                    return @as(Node.Index, @enumFromInt(node_index)).toOptional();
                },
                .literal => {},
                .space => {
                    const trailing = @intFromEnum(self.token_it.pos) - 2;
                    self.eatCommentsAndSpace(&.{});
                    if (self.token_it.peek()) |peek| {
                        if (peek.id != .literal) {
                            const node_end: Token.Index = @enumFromInt(trailing);
                            log.debug("(leaf) {s}", .{self.getRaw(node_start, node_end)});
                            self.nodes.set(node_index, .{
                                .tag = .value,
                                .scope = .{
                                    .start = node_start,
                                    .end = node_end,
                                },
                                .data = undefined,
                            });
                            return @as(Node.Index, @enumFromInt(node_index)).toOptional();
                        }
                    }
                },
                else => {
                    self.token_it.seekBy(-1);
                    const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);
                    log.debug("(leaf) {s}", .{self.getRaw(node_start, node_end)});
                    self.nodes.set(node_index, .{
                        .tag = .value,
                        .scope = .{
                            .start = node_start,
                            .end = node_end,
                        },
                        .data = undefined,
                    });
                    return @as(Node.Index, @enumFromInt(node_index)).toOptional();
                },
            }
        }

        return error.MalformedYaml;
    }

    fn eatCommentsAndSpace(self: *Parser, comptime exclusions: []const Token.Id) void {
        log.debug("eatCommentsAndSpace", .{});
        outer: while (self.token_it.next()) |token| {
            log.debug("  (token '{s}')", .{@tagName(token.id)});
            switch (token.id) {
                .comment, .space, .new_line => |space| {
                    inline for (exclusions) |excl| {
                        if (excl == space) {
                            self.token_it.seekBy(-1);
                            break :outer;
                        }
                    } else continue;
                },
                else => {
                    self.token_it.seekBy(-1);
                    break;
                },
            }
        }
    }

    fn eatToken(self: *Parser, id: Token.Id, comptime exclusions: []const Token.Id) ?Token.Index {
        log.debug("eatToken('{s}')", .{@tagName(id)});
        self.eatCommentsAndSpace(exclusions);
        const pos = self.token_it.pos;
        const token = self.token_it.next() orelse return null;
        if (token.id == id) {
            log.debug("  (found at {d})", .{pos});
            return pos;
        } else {
            log.debug("  (not found)", .{});
            self.token_it.seekBy(-1);
            return null;
        }
    }

    fn expectToken(self: *Parser, id: Token.Id, comptime exclusions: []const Token.Id) ParseError!Token.Index {
        log.debug("expectToken('{s}')", .{@tagName(id)});
        return self.eatToken(id, exclusions) orelse error.UnexpectedToken;
    }

    fn getLine(self: *Parser, index: Token.Index) usize {
        return self.tokens.items(.line_col)[@intFromEnum(index)].line;
    }

    fn getCol(self: *Parser, index: Token.Index) usize {
        return self.tokens.items(.line_col)[@intFromEnum(index)].col;
    }

    fn parseSingleQuoted(self: *Parser, raw: []const u8) ParseError!String {
        const gpa = self.allocator;

        assert(raw[0] == '\'' and raw[raw.len - 1] == '\'');
        const raw_no_quotes = raw[1 .. raw.len - 1];

        try self.string_bytes.ensureUnusedCapacity(gpa, raw_no_quotes.len);
        var string: String = .{
            .index = @enumFromInt(@as(u32, @intCast(self.string_bytes.items.len))),
            .len = 0,
        };

        var state: enum {
            start,
            escape,
        } = .start;

        var index: usize = 0;

        while (index < raw_no_quotes.len) : (index += 1) {
            const c = raw_no_quotes[index];
            switch (state) {
                .start => switch (c) {
                    '\'' => {
                        state = .escape;
                    },
                    else => {
                        self.string_bytes.appendAssumeCapacity(c);
                        string.len += 1;
                    },
                },
                .escape => switch (c) {
                    '\'' => {
                        state = .start;
                        self.string_bytes.appendAssumeCapacity(c);
                        string.len += 1;
                    },
                    else => return error.InvalidEscapeSequence,
                },
            }
        }

        return string;
    }

    fn parseDoubleQuoted(self: *Parser, raw: []const u8) ParseError!String {
        const gpa = self.allocator;

        assert(raw[0] == '"' and raw[raw.len - 1] == '"');
        const raw_no_quotes = raw[1 .. raw.len - 1];

        try self.string_bytes.ensureUnusedCapacity(gpa, raw_no_quotes.len);
        var string: String = .{
            .index = @enumFromInt(@as(u32, @intCast(self.string_bytes.items.len))),
            .len = 0,
        };

        var state: enum {
            start,
            escape,
        } = .start;

        var index: usize = 0;

        while (index < raw_no_quotes.len) : (index += 1) {
            const c = raw_no_quotes[index];
            switch (state) {
                .start => switch (c) {
                    '\\' => {
                        state = .escape;
                    },
                    else => {
                        self.string_bytes.appendAssumeCapacity(c);
                        string.len += 1;
                    },
                },
                .escape => switch (c) {
                    'n' => {
                        state = .start;
                        self.string_bytes.appendAssumeCapacity('\n');
                        string.len += 1;
                    },
                    't' => {
                        state = .start;
                        self.string_bytes.appendAssumeCapacity('\t');
                        string.len += 1;
                    },
                    '"' => {
                        state = .start;
                        self.string_bytes.appendAssumeCapacity('"');
                        string.len += 1;
                    },
                    else => return error.InvalidEscapeSequence,
                },
            }
        }

        return string;
    }

    fn getRaw(self: Parser, start: Token.Index, end: Token.Index) []const u8 {
        const start_token = self.getToken(start);
        const end_token = self.getToken(end);
        return self.source[start_token.loc.start..end_token.loc.end];
    }

    fn getToken(self: Parser, index: Token.Index) Token {
        return self.tokens.items(.token)[@intFromEnum(index)];
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("parse/test.zig");
}
