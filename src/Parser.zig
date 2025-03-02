const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.parser);
const mem = std.mem;

const Allocator = mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const LineCol = Tree.LineCol;
const List = Tree.List;
const Map = Tree.Map;
const Node = Tree.Node;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const TokenIterator = Tokenizer.TokenIterator;
const TokenWithLineCol = Tree.TokenWithLineCol;
const Tree = @import("Tree.zig");
const String = Tree.String;
const Parser = @This();
const Yaml = @import("Yaml.zig");

source: []const u8,
tokens: std.MultiArrayList(TokenWithLineCol) = .empty,
token_it: TokenIterator = undefined,
docs: std.ArrayListUnmanaged(Node.Index) = .empty,
nodes: std.MultiArrayList(Node) = .empty,
extra: std.ArrayListUnmanaged(u32) = .empty,
string_bytes: std.ArrayListUnmanaged(u8) = .empty,
errors: ErrorBundle.Wip,

pub fn init(gpa: Allocator, source: []const u8) Allocator.Error!Parser {
    var self: Parser = .{ .source = source, .errors = undefined };
    try self.errors.init(gpa);
    return self;
}

pub fn deinit(self: *Parser, gpa: Allocator) void {
    self.tokens.deinit(gpa);
    self.docs.deinit(gpa);
    self.nodes.deinit(gpa);
    self.extra.deinit(gpa);
    self.string_bytes.deinit(gpa);
    self.errors.deinit();
    self.* = undefined;
}

pub fn parse(self: *Parser, gpa: Allocator) ParseError!void {
    var tokenizer = Tokenizer{ .buffer = self.source };
    var line: u32 = 0;
    var prev_line_last_col: u32 = 0;

    while (true) {
        const tok = tokenizer.next();
        const tok_index = try self.tokens.addOne(gpa);

        self.tokens.set(tok_index, .{
            .token = tok,
            .line_col = .{
                .line = line,
                .col = @intCast(tok.loc.start - prev_line_last_col),
            },
        });

        switch (tok.id) {
            .eof => break,
            .new_line => {
                line += 1;
                prev_line_last_col = @intCast(tok.loc.end);
            },
            else => {},
        }
    }

    self.token_it = .{ .buffer = self.tokens.items(.token) };

    self.eatCommentsAndSpace(&.{});

    while (true) {
        self.eatCommentsAndSpace(&.{});
        const tok = self.token_it.next() orelse break;

        log.debug("(main) next {s}@{d}", .{ @tagName(tok.id), @intFromEnum(self.token_it.pos) - 1 });

        switch (tok.id) {
            .eof => break,
            else => {
                self.token_it.seekBy(-1);
                const node_index = try self.doc(gpa);
                try self.docs.append(gpa, node_index);
            },
        }
    }
}

pub fn toOwnedTree(self: *Parser, gpa: Allocator) Allocator.Error!Tree {
    return .{
        .source = self.source,
        .tokens = self.tokens.toOwnedSlice(),
        .docs = try self.docs.toOwnedSlice(gpa),
        .nodes = self.nodes.toOwnedSlice(),
        .extra = try self.extra.toOwnedSlice(gpa),
        .string_bytes = try self.string_bytes.toOwnedSlice(gpa),
    };
}

fn addString(self: *Parser, gpa: Allocator, string: []const u8) Allocator.Error!String {
    const index: u32 = @intCast(self.string_bytes.items.len);
    try self.string_bytes.ensureUnusedCapacity(gpa, string.len);
    self.string_bytes.appendSliceAssumeCapacity(string);
    return .{ .index = @enumFromInt(index), .len = @intCast(string.len) };
}

fn addExtra(self: *Parser, gpa: Allocator, extra: anytype) Allocator.Error!u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    try self.extra.ensureUnusedCapacity(gpa, fields.len);
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

fn value(self: *Parser, gpa: Allocator) ParseError!Node.OptionalIndex {
    self.eatCommentsAndSpace(&.{});

    const pos = self.token_it.pos;
    const tok = self.token_it.next() orelse return error.UnexpectedEof;

    log.debug("  next {s}@{d}", .{ @tagName(tok.id), pos });

    switch (tok.id) {
        .literal => if (self.eatToken(.map_value_ind, &.{ .new_line, .comment })) |_| {
            // map
            self.token_it.seekTo(pos);
            return self.map(gpa);
        } else {
            // leaf value
            self.token_it.seekTo(pos);
            return self.leafValue(gpa);
        },
        .single_quoted, .double_quoted => {
            // leaf value
            self.token_it.seekBy(-1);
            return self.leafValue(gpa);
        },
        .seq_item_ind => {
            // list
            self.token_it.seekBy(-1);
            return self.list(gpa);
        },
        .flow_seq_start => {
            // list
            self.token_it.seekBy(-1);
            return self.listBracketed(gpa);
        },
        else => return .none,
    }
}

fn doc(self: *Parser, gpa: Allocator) ParseError!Node.Index {
    const node_index = try self.nodes.addOne(gpa);
    const node_start = self.token_it.pos;

    log.debug("(doc) begin {s}@{d}", .{ @tagName(self.token(node_start).id), node_start });

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
    const value_index = try self.value(gpa);
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

        return self.fail(gpa, self.token_it.pos, "expected end of document", .{});
    };

    log.debug("(doc) end {s}@{d}", .{ @tagName(self.token(node_end).id), node_end });

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

fn map(self: *Parser, gpa: Allocator) ParseError!Node.OptionalIndex {
    const node_index = try self.nodes.addOne(gpa);
    const node_start = self.token_it.pos;

    var entries: std.ArrayListUnmanaged(Map.Entry) = .empty;
    defer entries.deinit(gpa);

    log.debug("(map) begin {s}@{d}", .{ @tagName(self.token(node_start).id), node_start });

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
            else => return self.fail(gpa, self.token_it.pos, "unexpected token for 'key': {}", .{key}),
        }

        log.debug("(map) key {s}@{d}", .{ self.rawString(key_pos, key_pos), key_pos });

        // Separator
        _ = self.expectToken(.map_value_ind, &.{ .new_line, .comment }) catch
            return self.fail(gpa, self.token_it.pos, "expected map separator ':'", .{});

        // Parse value
        const value_index = try self.value(gpa);

        if (value_index.unwrap()) |v| {
            const value_start = self.nodes.items(.scope)[@intFromEnum(v)].start;
            if (self.getCol(value_start) < self.getCol(key_pos)) {
                return error.MalformedYaml;
            }
            if (self.nodes.items(.tag)[@intFromEnum(v)] == .value) {
                if (self.getCol(value_start) == self.getCol(key_pos)) {
                    return self.fail(gpa, value_start, "'value' in map should have more indentation than the 'key'", .{});
                }
            }
        }

        try entries.append(gpa, .{
            .key = key_pos,
            .maybe_node = value_index,
        });
    }

    const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);

    log.debug("(map) end {s}@{d}", .{ @tagName(self.token(node_end).id), node_end });

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

fn list(self: *Parser, gpa: Allocator) ParseError!Node.OptionalIndex {
    const node_index: Node.Index = @enumFromInt(try self.nodes.addOne(gpa));
    const node_start = self.token_it.pos;

    var values: std.ArrayListUnmanaged(List.Entry) = .empty;
    defer values.deinit(gpa);

    const first_col = self.getCol(node_start);

    log.debug("(list) begin {s}@{d}", .{ @tagName(self.token(node_start).id), node_start });

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

        const value_index = try self.value(gpa);
        if (value_index == .none) return error.MalformedYaml;

        try values.append(gpa, .{ .node = value_index.unwrap().? });
    }

    const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);

    log.debug("(list) end {s}@{d}", .{ @tagName(self.token(node_end).id), node_end });

    try self.encodeList(gpa, node_index, values.items, .{
        .start = node_start,
        .end = node_end,
    });

    return node_index.toOptional();
}

fn listBracketed(self: *Parser, gpa: Allocator) ParseError!Node.OptionalIndex {
    const node_index: Node.Index = @enumFromInt(try self.nodes.addOne(gpa));
    const node_start = self.token_it.pos;

    var values: std.ArrayListUnmanaged(List.Entry) = .empty;
    defer values.deinit(gpa);

    log.debug("(list) begin {s}@{d}", .{ @tagName(self.token(node_start).id), node_start });

    _ = try self.expectToken(.flow_seq_start, &.{});

    const node_end: Token.Index = while (true) {
        self.eatCommentsAndSpace(&.{.comment});

        if (self.eatToken(.flow_seq_end, &.{.comment})) |pos|
            break pos;

        _ = self.eatToken(.comma, &.{.comment});

        const value_index = try self.value(gpa);
        if (value_index == .none) return error.MalformedYaml;

        try values.append(gpa, .{ .node = value_index.unwrap().? });
    };

    log.debug("(list) end {s}@{d}", .{ @tagName(self.token(node_end).id), node_end });

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

fn leafValue(self: *Parser, gpa: Allocator) ParseError!Node.OptionalIndex {
    const node_index: Node.Index = @enumFromInt(try self.nodes.addOne(gpa));
    const node_start = self.token_it.pos;

    // TODO handle multiline strings in new block scope
    while (self.token_it.next()) |tok| {
        switch (tok.id) {
            .single_quoted => {
                const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);
                const raw = self.rawString(node_start, node_end);
                log.debug("(leaf) {s}", .{raw});
                assert(raw.len > 0);
                const string = try self.parseSingleQuoted(gpa, raw);

                self.nodes.set(@intFromEnum(node_index), .{
                    .tag = .string_value,
                    .scope = .{
                        .start = node_start,
                        .end = node_end,
                    },
                    .data = .{ .string = string },
                });

                return node_index.toOptional();
            },
            .double_quoted => {
                const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);
                const raw = self.rawString(node_start, node_end);
                log.debug("(leaf) {s}", .{raw});
                assert(raw.len > 0);
                const string = try self.parseDoubleQuoted(gpa, raw);

                self.nodes.set(@intFromEnum(node_index), .{
                    .tag = .string_value,
                    .scope = .{
                        .start = node_start,
                        .end = node_end,
                    },
                    .data = .{ .string = string },
                });

                return node_index.toOptional();
            },
            .literal => {},
            .space => {
                const trailing = @intFromEnum(self.token_it.pos) - 2;
                self.eatCommentsAndSpace(&.{});
                if (self.token_it.peek()) |peek| {
                    if (peek.id != .literal) {
                        const node_end: Token.Index = @enumFromInt(trailing);
                        log.debug("(leaf) {s}", .{self.rawString(node_start, node_end)});
                        self.nodes.set(@intFromEnum(node_index), .{
                            .tag = .value,
                            .scope = .{
                                .start = node_start,
                                .end = node_end,
                            },
                            .data = undefined,
                        });
                        return node_index.toOptional();
                    }
                }
            },
            else => {
                self.token_it.seekBy(-1);
                const node_end: Token.Index = @enumFromInt(@intFromEnum(self.token_it.pos) - 1);
                log.debug("(leaf) {s}", .{self.rawString(node_start, node_end)});
                self.nodes.set(@intFromEnum(node_index), .{
                    .tag = .value,
                    .scope = .{
                        .start = node_start,
                        .end = node_end,
                    },
                    .data = undefined,
                });
                return node_index.toOptional();
            },
        }
    }

    return error.MalformedYaml;
}

fn eatCommentsAndSpace(self: *Parser, comptime exclusions: []const Token.Id) void {
    log.debug("eatCommentsAndSpace", .{});
    outer: while (self.token_it.next()) |tok| {
        log.debug("  (token '{s}')", .{@tagName(tok.id)});
        switch (tok.id) {
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
    const tok = self.token_it.next() orelse return null;
    if (tok.id == id) {
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

fn parseSingleQuoted(self: *Parser, gpa: Allocator, raw: []const u8) ParseError!String {
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

fn parseDoubleQuoted(self: *Parser, gpa: Allocator, raw: []const u8) ParseError!String {
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

fn rawString(self: Parser, start: Token.Index, end: Token.Index) []const u8 {
    const start_token = self.token(start);
    const end_token = self.token(end);
    return self.source[start_token.loc.start..end_token.loc.end];
}

fn token(self: Parser, index: Token.Index) Token {
    return self.tokens.items(.token)[@intFromEnum(index)];
}

fn fail(self: *Parser, gpa: Allocator, token_index: Token.Index, comptime format: []const u8, args: anytype) ParseError {
    const line_col = self.tokens.items(.line_col)[@intFromEnum(token_index)];
    const msg = try std.fmt.allocPrint(gpa, format, args);
    defer gpa.free(msg);
    const line_info = getLineInfo(self.source, line_col);
    try self.errors.addRootErrorMessage(.{
        .msg = try self.errors.addString(msg),
        .src_loc = try self.errors.addSourceLocation(.{
            .src_path = try self.errors.addString("(memory)"),
            .line = line_col.line,
            .column = line_col.col,
            .span_start = line_info.span_start,
            .span_main = line_info.span_main,
            .span_end = line_info.span_end,
            .source_line = try self.errors.addString(line_info.line),
        }),
        .notes_len = 0,
    });
    return error.ParseFailure;
}

fn getLineInfo(source: []const u8, line_col: LineCol) struct {
    line: []const u8,
    span_start: u32,
    span_main: u32,
    span_end: u32,
} {
    const line = line: {
        var it = mem.splitScalar(u8, source, '\n');
        var line_count: usize = 0;
        const line = while (it.next()) |line| {
            defer line_count += 1;
            if (line_count == line_col.line) break line;
        } else return .{
            .line = &.{},
            .span_start = 0,
            .span_main = 0,
            .span_end = 0,
        };
        break :line line;
    };

    const span_start: u32 = span_start: {
        const trimmed = mem.trimLeft(u8, line, " ");
        break :span_start @intCast(mem.indexOf(u8, line, trimmed).?);
    };

    const span_end: u32 = @intCast(mem.trimRight(u8, line, " \r\n").len);

    return .{
        .line = line,
        .span_start = span_start,
        .span_main = line_col.col,
        .span_end = span_end,
    };
}

pub const ParseError = error{
    InvalidEscapeSequence,
    MalformedYaml,
    NestedDocuments,
    UnexpectedEof,
    UnexpectedToken,
    ParseFailure,
} || Allocator.Error;

test {
    std.testing.refAllDecls(@This());
    _ = @import("Parser/test.zig");
}
