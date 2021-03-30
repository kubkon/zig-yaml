const std = @import("std");
const log = std.log.scoped(.parse);
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const TokenIndex = usize;

pub const Node = struct {
    tag: Tag,

    pub const Tag = enum {
        Root,
        Document,
    };

    pub fn deinit(self: *Node, allocator: *Allocator) void {
        switch (self.tag) {
            .Root => @fieldParentPtr(Node.Root, "base", self).deinit(allocator),
            .Document => @fieldParentPtr(Node.Document, "base", self).deinit(allocator),
        }
    }

    pub const Root = struct {
        base: Node = Node{ .tag = Tag.Root },
        items: std.ArrayListUnmanaged(*Node) = .{},

        pub fn deinit(self: *Root, allocator: *Allocator) void {
            for (self.items.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.items.deinit(allocator);
        }
    };

    pub const Document = struct {
        base: Node = Node{ .tag = Tag.Document },
        start: ?TokenIndex = null,
        directive: ?TokenIndex = null,
        values: std.ArrayListUnmanaged(*Node) = .{},
        end: ?TokenIndex = null,

        pub fn deinit(self: *Document, allocator: *Allocator) void {
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
    tree.root = try parseRoot(allocator, &tree);

    return tree;
}

fn parseRoot(allocator: *Allocator, tree: *Tree) !*Node.Root {
    var root = try allocator.create(Node.Root);
    root.* = .{};

    var stack = std.ArrayList(*Node).init(allocator);
    defer stack.deinit();

    var token_index: usize = 0;
    while (token_index < tree.tokens.len) : (token_index += 1) {
        const token = tree.tokens[token_index];

        switch (token.id) {
            .DocStart => {
                var doc = try allocator.create(Node.Document);
                doc.* = .{};
                doc.start = token_index;
                try stack.append(&doc.base);
            },
            .DocEnd => {
                var node = stack.pop();
                var doc = @fieldParentPtr(Node.Document, "base", node);
                doc.end = token_index;
                try root.items.append(allocator, &doc.base);
            },
            else => {},
        }
    }

    return root;
}

test "hmm" {
    const source =
        \\--- !tapi-tbd
        \\...
    ;

    var tree = try parse(testing.allocator, source);
    defer tree.deinit();

    std.debug.print("{any}\n", .{tree});
    std.debug.print("{any}\n", .{tree.root.*});
    const doc = @fieldParentPtr(Node.Document, "base", tree.root.items.items[0]);
    std.debug.print("{any}\n", .{doc});
}
