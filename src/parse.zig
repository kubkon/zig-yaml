const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.parse);
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const TokenIndex = Tokenizer.TokenIndex;
const TokenIterator = Tokenizer.TokenIterator;

pub const Node = struct {
    tag: Tag,
    tree: *const Tree,

    pub const Tag = enum {
        Root,
        Doc,
        Map,
        Value,
    };

    pub const Error = std.os.WriteError;

    pub fn deinit(self: *Node, allocator: *Allocator) void {
        switch (self.tag) {
            .Root => @fieldParentPtr(Node.Root, "base", self).deinit(allocator),
            .Doc => @fieldParentPtr(Node.Doc, "base", self).deinit(allocator),
            .Map => @fieldParentPtr(Node.Map, "base", self).deinit(allocator),
            .Value => @fieldParentPtr(Node.Value, "base", self).deinit(allocator),
        }
    }

    pub fn format(
        self: *const Node,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return switch (self.tag) {
            .Root => @fieldParentPtr(Node.Root, "base", self).format(fmt, options, writer),
            .Doc => @fieldParentPtr(Node.Doc, "base", self).format(fmt, options, writer),
            .Map => @fieldParentPtr(Node.Map, "base", self).format(fmt, options, writer),
            .Value => @fieldParentPtr(Node.Value, "base", self).format(fmt, options, writer),
        };
    }

    pub const Root = struct {
        base: Node = Node{ .tag = Tag.Root, .tree = undefined },
        docs: std.ArrayListUnmanaged(*Node) = .{},
        eof: ?TokenIndex = null,

        pub fn deinit(self: *Root, allocator: *Allocator) void {
            for (self.docs.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.docs.deinit(allocator);
        }

        pub fn format(
            self: *const Root,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try std.fmt.format(writer, "Root {{ .docs = [ ", .{});
            for (self.docs.items) |node| {
                try std.fmt.format(writer, "{} ,", .{node});
            }
            return std.fmt.format(writer, "] }}", .{});
        }
    };

    pub const Doc = struct {
        base: Node = Node{ .tag = Tag.Doc, .tree = undefined },
        start: ?TokenIndex = null,
        directive: ?TokenIndex = null,
        values: std.ArrayListUnmanaged(*Node) = .{},
        end: ?TokenIndex = null,

        pub fn deinit(self: *Doc, allocator: *Allocator) void {
            for (self.values.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.values.deinit(allocator);
        }

        pub fn format(
            self: *const Doc,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const directive = self.base.tree.tokens[self.directive.?];
            try std.fmt.format(writer, "Doc {{ .directive = {s}, .values = [ ", .{
                self.base.tree.source[directive.start..directive.end],
            });
            for (self.values.items) |node| {
                try std.fmt.format(writer, "{} ,", .{node});
            }
            return std.fmt.format(writer, "] }}", .{});
        }
    };

    pub const Map = struct {
        base: Node = Node{ .tag = Tag.Map, .tree = undefined },
        key: ?TokenIndex = null,
        value: ?*Node = null,

        pub fn deinit(self: *Map, allocator: *Allocator) void {
            if (self.value) |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            }
        }

        pub fn format(
            self: *const Map,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const key = self.base.tree.tokens[self.key.?];
            return std.fmt.format(writer, "Map {{ .key = {s}, .value = {} }}", .{
                self.base.tree.source[key.start..key.end],
                self.value.?,
            });
        }
    };

    pub const Value = struct {
        base: Node = Node{ .tag = Tag.Value, .tree = undefined },
        value: ?TokenIndex = null,

        pub fn deinit(self: *Value, allocator: *Allocator) void {}

        pub fn format(
            self: *const Value,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const token = self.base.tree.tokens[self.value.?];
            return std.fmt.format(writer, "Value {{ .value = {s} }}", .{
                self.base.tree.source[token.start..token.end],
            });
        }
    };
};

pub const Tree = struct {
    allocator: *Allocator,
    source: []const u8,
    tokens: []Token,
    root: *Node.Root,

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.tokens);
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }
};

pub fn parse(allocator: *Allocator, source: []const u8) !Tree {
    var tokenizer = Tokenizer{
        .buffer = source,
    };
    var tokens = std.ArrayList(Token).init(allocator);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(token);
        if (token.id == .Eof) break;
    }

    var tree = Tree{
        .allocator = allocator,
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .root = undefined,
    };
    var it = TokenIterator{
        .buffer = tree.tokens,
    };
    var parser = Parser{
        .allocator = allocator,
        .tree = &tree,
        .token_it = &it,
    };
    defer parser.deinit();
    tree.root = try parser.root();

    return tree;
}

const Parser = struct {
    allocator: *Allocator,
    tree: *Tree,
    token_it: *TokenIterator,

    fn deinit(self: *Parser) void {}

    fn root(self: *Parser) !*Node.Root {
        const node = try self.allocator.create(Node.Root);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;

        while (true) {
            if (self.token_it.peek()) |token| {
                if (token.id == .Eof) {
                    _ = self.token_it.next();
                    node.eof = self.token_it.getPos();
                    break;
                }
            }

            std.debug.print("\n\n", .{});
            const doc_node = try self.doc();
            try node.docs.append(self.allocator, &doc_node.base);
        }

        return node;
    }

    fn doc(self: *Parser) !*Node.Doc {
        const node = try self.allocator.create(Node.Doc);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;

        if (self.eatToken(.DocStart)) |_| {
            if (self.eatToken(.Tag)) |_| {
                node.directive = try self.expectToken(.Literal);
            }
        }

        _ = try self.expectToken(.NewLine);

        while (true) {
            const token = self.token_it.next();
            std.debug.print("{any} => {s}\n", .{
                token.id,
                self.tree.source[token.start..token.end],
            });
            switch (token.id) {
                .DocStart => {
                    // TODO this should be an error token
                    return error.NestedDocuments;
                },
                .Tag => {
                    return error.UnexpectedTag;
                },
                .Literal => {
                    const curr_pos = self.token_it.getPos();
                    _ = try self.expectToken(.MapValueInd);
                    self.eatCommentsAndSpace();
                    if (self.eatToken(.NewLine)) |tok| {
                        std.debug.print("...opening new scope", .{});
                        std.debug.print("  | {any}", .{self.tree.tokens[tok]});
                        // TODO verify indendation/scope
                    }
                    const map_node = try self.map();
                    map_node.key = curr_pos;
                    try node.values.append(self.allocator, &map_node.base);
                },
                .DocEnd => {
                    node.end = self.token_it.getPos();
                    break;
                },
                .Eof => {
                    return error.UnexpectedEof;
                },
                else => {},
            }
        }

        return node;
    }

    fn map(self: *Parser) !*Node.Map {
        const node = try self.allocator.create(Node.Map);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;

        while (true) {
            const token = self.token_it.next();
            std.debug.print("  | {any} => {s}\n", .{
                token.id,
                self.tree.source[token.start..token.end],
            });
            switch (token.id) {
                .Literal => {
                    const value = try self.allocator.create(Node.Value);
                    errdefer self.allocator.destroy(value);
                    value.* = .{
                        .value = self.token_it.getPos(),
                    };
                    value.base.tree = self.tree;
                    node.value = &value.base;
                },
                else => return error.Unhandled,
            }
        }

        return node;
    }

    fn eatCommentsAndSpace(self: *Parser) void {
        while (true) {
            const cur_pos = self.token_it.getPos();
            _ = self.token_it.peek() orelse return;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .Space => {},
                else => break,
            }
        }
    }

    fn eatToken(self: *Parser, id: Token.Id) ?TokenIndex {
        while (true) {
            const cur_pos = self.token_it.getPos();
            _ = self.token_it.peek() orelse return null;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .Space => continue,
                else => |next_id| if (next_id == id) {
                    return self.token_it.getPos();
                } else {
                    self.token_it.resetTo(cur_pos);
                    return null;
                },
            }
        }
    }

    fn expectToken(self: *Parser, id: Token.Id) !TokenIndex {
        return self.eatToken(id) orelse error.UnexpectedToken;
    }
};

test "hmm" {
    const source =
        \\--- !tapi-tbd
        // \\tbd-version: 4
        \\...
    ;

    var tree = try parse(testing.allocator, source);
    defer tree.deinit();

    std.debug.print("{}", .{tree.root});
}
