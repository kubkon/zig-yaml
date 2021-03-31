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

    pub const Tag = enum {
        Root,
        Doc,
    };

    pub fn deinit(self: *Node, allocator: *Allocator) void {
        switch (self.tag) {
            .Root => @fieldParentPtr(Node.Root, "base", self).deinit(allocator),
            .Doc => @fieldParentPtr(Node.Doc, "base", self).deinit(allocator),
        }
    }

    pub const Root = struct {
        base: Node = Node{ .tag = Tag.Root },
        docs: std.ArrayListUnmanaged(*Node) = .{},
        eof: ?TokenIndex = null,

        pub fn deinit(self: *Root, allocator: *Allocator) void {
            for (self.docs.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.docs.deinit(allocator);
        }
    };

    pub const Doc = struct {
        base: Node = Node{ .tag = Tag.Doc },
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
        .token_it = &it,
    };
    defer parser.deinit();
    tree.root = try parser.root();

    return tree;
}

const Parser = struct {
    allocator: *Allocator,
    token_it: *TokenIterator,
    stack: std.ArrayListUnmanaged(*Node) = .{},

    fn deinit(self: *Parser) void {
        self.stack.deinit(self.allocator);
    }

    fn root(self: *Parser) !*Node.Root {
        var node = try self.allocator.create(Node.Root);
        errdefer self.allocator.destroy(node);
        node.* = .{};

        while (true) {
            if (self.token_it.peek()) |token| {
                if (token.id == .Eof) {
                    _ = self.token_it.next();
                    node.eof = self.token_it.getPos();
                    break;
                }
            }

            var doc_node = try self.doc();
            try node.docs.append(self.allocator, &doc_node.base);
        }

        return node;
    }

    fn doc(self: *Parser) !*Node.Doc {
        var node = try self.allocator.create(Node.Doc);
        errdefer self.allocator.destroy(node);
        node.* = .{};

        if (self.eatToken(.DocStart)) |_| {
            if (self.eatToken(.Tag)) |_| {
                node.directive = try self.expectToken(.Literal);
            }
        }

        while (true) {
            const token = self.token_it.next();
            if (token.id == .Eof) {
                return error.UnexpectedEof;
            }

            std.debug.print("{any}\n", .{token.id});
            switch (token.id) {
                .DocStart => {
                    // TODO this should be an error token
                    return error.NestedDocuments;
                },
                .Tag => {
                    return error.UnexpectedTag;
                },
                .DocEnd => {
                    node.end = self.token_it.getPos();
                    break;
                },
                else => {},
            }
        }

        return node;
    }

    fn eatToken(self: *Parser, id: Token.Id) ?TokenIndex {
        while (true) {
            const cur_pos = self.token_it.getPos();
            _ = self.token_it.peek() orelse return null;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .NewLine, .Space => continue,
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
        while (true) {
            _ = self.token_it.peek() orelse return error.UnexpectedEof;
            const next = self.token_it.next();
            switch (next.id) {
                .Comment, .NewLine, .Space => continue,
                else => |next_id| if (next_id != id) {
                    return error.UnexpectedToken;
                } else {
                    return self.token_it.getPos();
                },
            }
        }
    }
};

test "hmm" {
    const source =
        \\--- !tapi-tbd
        \\...
    ;

    var tree = try parse(testing.allocator, source);
    defer tree.deinit();

    std.debug.print("{any}\n", .{tree});
    std.debug.print("{any}\n", .{tree.root.*});
    const doc = @fieldParentPtr(Node.Doc, "base", tree.root.docs.items[0]);
    std.debug.print("{any}\n", .{doc});
}
