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
        doc,
        map,
        list,
        value,
    };

    pub fn cast(self: *const Node, comptime T: type) ?*const T {
        if (self.tag != T.base_tag) {
            return null;
        }
        return @fieldParentPtr(T, "base", self);
    }

    pub fn deinit(self: *Node, allocator: *Allocator) void {
        switch (self.tag) {
            .doc => @fieldParentPtr(Node.Doc, "base", self).deinit(allocator),
            .map => @fieldParentPtr(Node.Map, "base", self).deinit(allocator),
            .list => @fieldParentPtr(Node.List, "base", self).deinit(allocator),
            .value => @fieldParentPtr(Node.Value, "base", self).deinit(allocator),
        }
    }

    pub fn format(
        self: *const Node,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return switch (self.tag) {
            .doc => @fieldParentPtr(Node.Doc, "base", self).format(fmt, options, writer),
            .map => @fieldParentPtr(Node.Map, "base", self).format(fmt, options, writer),
            .list => @fieldParentPtr(Node.List, "base", self).format(fmt, options, writer),
            .value => @fieldParentPtr(Node.Value, "base", self).format(fmt, options, writer),
        };
    }

    pub const Doc = struct {
        base: Node = Node{ .tag = Tag.doc, .tree = undefined },
        start: ?TokenIndex = null,
        end: ?TokenIndex = null,
        directive: ?TokenIndex = null,
        value: ?*Node = null,

        pub const base_tag: Node.Tag = .doc;

        pub fn deinit(self: *Doc, allocator: *Allocator) void {
            if (self.value) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
        }

        pub fn format(
            self: *const Doc,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try std.fmt.format(writer, "Doc {{ ", .{});
            if (self.directive) |id| {
                const directive = self.base.tree.tokens[id];
                try std.fmt.format(writer, ".directive = {s}, ", .{
                    self.base.tree.source[directive.start..directive.end],
                });
            }
            if (self.value) |node| {
                try std.fmt.format(writer, ".value = {}", .{node});
            }
            return std.fmt.format(writer, " }}", .{});
        }
    };

    pub const Map = struct {
        base: Node = Node{ .tag = Tag.map, .tree = undefined },
        start: ?TokenIndex = null,
        end: ?TokenIndex = null,
        values: std.ArrayListUnmanaged(Entry) = .{},

        pub const base_tag: Node.Tag = .map;

        pub const Entry = struct {
            key: TokenIndex,
            value: *Node,
        };

        pub fn deinit(self: *Map, allocator: *Allocator) void {
            for (self.values.items) |entry| {
                entry.value.deinit(allocator);
                allocator.destroy(entry.value);
            }
            self.values.deinit(allocator);
        }

        pub fn format(
            self: *const Map,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try std.fmt.format(writer, "Map {{ .values = {{ ", .{});
            for (self.values.items) |entry| {
                const key = self.base.tree.tokens[entry.key];
                try std.fmt.format(writer, "{s} => {}, ", .{
                    self.base.tree.source[key.start..key.end],
                    entry.value,
                });
            }
            return std.fmt.format(writer, " }}", .{});
        }
    };

    pub const List = struct {
        base: Node = Node{ .tag = Tag.list, .tree = undefined },
        start: ?TokenIndex = null,
        end: ?TokenIndex = null,
        values: std.ArrayListUnmanaged(*Node) = .{},

        pub const base_tag: Node.Tag = .list;

        pub fn deinit(self: *List, allocator: *Allocator) void {
            for (self.values.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.values.deinit(allocator);
        }

        pub fn format(
            self: *const List,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try std.fmt.format(writer, "List {{ .values = [ ", .{});
            for (self.values.items) |node| {
                try std.fmt.format(writer, "{}, ", .{node});
            }
            return std.fmt.format(writer, "] }}", .{});
        }
    };

    pub const Value = struct {
        base: Node = Node{ .tag = Tag.value, .tree = undefined },
        value: ?TokenIndex = null,

        pub const base_tag: Node.Tag = .value;

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
    docs: std.ArrayListUnmanaged(*Node.Doc) = .{},

    pub fn init(allocator: *Allocator) Tree {
        return .{
            .allocator = allocator,
            .source = undefined,
            .tokens = undefined,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.tokens);
        for (self.docs.items) |doc| {
            doc.deinit(self.allocator);
            self.allocator.destroy(doc);
        }
        self.docs.deinit(self.allocator);
    }

    pub fn parse(self: *Tree, source: []const u8) !void {
        var tokenizer = Tokenizer{ .buffer = source };
        var tokens = std.ArrayList(Token).init(self.allocator);
        errdefer tokens.deinit();

        while (true) {
            const token = tokenizer.next();
            try tokens.append(token);
            if (token.id == .Eof) break;
        }

        self.source = source;
        self.tokens = tokens.toOwnedSlice();

        var it = TokenIterator{ .buffer = self.tokens };
        var parser = Parser{
            .allocator = self.allocator,
            .tree = self,
            .token_it = &it,
        };
        defer parser.deinit();

        while (true) {
            const next = parser.token_it.peek() orelse break;
            if (next.id == .Eof) {
                _ = parser.token_it.next();
                break;
            }

            const doc = try parser.doc(parser.token_it.getPos());
            try self.docs.append(self.allocator, doc);
        }
    }
};

const Parser = struct {
    allocator: *Allocator,
    tree: *Tree,
    token_it: *TokenIterator,

    const ParseError = error{
        MalformedYaml,
        NestedDocuments,
        UnexpectedTag,
        UnexpectedEof,
        UnexpectedToken,
        Unhandled,
    } || Allocator.Error;

    fn deinit(self: *Parser) void {}

    fn doc(self: *Parser, start: TokenIndex) ParseError!*Node.Doc {
        const node = try self.allocator.create(Node.Doc);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        if (self.eatToken(.DocStart)) |_| {
            if (self.eatToken(.Tag)) |_| {
                node.directive = try self.expectToken(.Literal);
            }
        }

        _ = try self.expectToken(.NewLine);

        while (true) {
            const curr_pos = self.token_it.getPos();
            const token = self.token_it.next();
            switch (token.id) {
                .DocStart => {
                    // TODO this should be an error token
                    return error.NestedDocuments;
                },
                .Tag => {
                    return error.UnexpectedTag;
                },
                .Literal => {
                    _ = try self.expectToken(.MapValueInd);
                    const map_node = try self.map(curr_pos, 0);
                    node.value = &map_node.base;
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

    fn map(self: *Parser, start: TokenIndex, indent: usize) ParseError!*Node.Map {
        const node = try self.allocator.create(Node.Map);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        self.token_it.resetTo(start);

        while (true) {
            const scope = scope: {
                const peek = self.token_it.peek() orelse return error.UnexpectedEof;
                if (peek.id != .Space and peek.id != .Tab) {
                    break :scope indent;
                }
                break :scope indent + self.token_it.next().count.?;
            };

            if (scope < indent) break;

            // Parse key.
            const key = self.token_it.next();
            const key_index = self.token_it.getPos();
            switch (key.id) {
                .Literal => {},
                .DocEnd => {
                    self.token_it.resetTo(key_index - 1);
                    break;
                },
                else => {
                    // TODO bubble up error.
                    return error.UnexpectedToken;
                },
            }

            // Separator
            _ = try self.expectToken(.MapValueInd);

            // Parse value.
            const value: *Node = value: {
                if (self.eatToken(.NewLine)) |_| {
                    // Explicit, complex value such as list or map.
                    const new_indent = new_indent: {
                        const peek = self.token_it.peek() orelse return error.UnexpectedEof;
                        if (peek.id != .Space and peek.id != .Tab) {
                            return error.UnexpectedToken;
                        }
                        const new_indent = self.token_it.next().count.?;
                        if (new_indent < indent) {
                            return error.MalformedYaml;
                        }
                        break :new_indent new_indent;
                    };
                    const value = self.token_it.next();
                    switch (value.id) {
                        .Literal => {
                            // Assume nested map.
                            const map_node = try self.map(self.token_it.getPos(), new_indent);
                            break :value &map_node.base;
                        },
                        .SeqItemInd => {
                            // Assume list of values.
                            const list_node = try self.list(self.token_it.getPos(), new_indent);
                            break :value &list_node.base;
                        },
                        else => return error.Unhandled,
                    }
                } else {
                    const value = self.token_it.next();
                    switch (value.id) {
                        .Literal => {
                            // Assume leaf value.
                            const leaf_node = try self.leaf_value();
                            break :value &leaf_node.base;
                        },
                        else => return error.Unhandled,
                    }
                }
            };
            try node.values.append(self.allocator, .{
                .key = key_index,
                .value = value,
            });

            _ = try self.expectToken(.NewLine);
            node.end = self.token_it.getPos() - 1;
        }

        return node;
    }

    fn list(self: *Parser, start: TokenIndex, indent: usize) ParseError!*Node.List {
        const node = try self.allocator.create(Node.List);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        self.token_it.resetTo(start);

        while (true) {
            _ = self.eatToken(.SeqItemInd) orelse break;

            const new_indent = new_indent: {
                const peek = self.token_it.peek() orelse return error.UnexpectedEof;
                if (peek.id != .Space and peek.id != .Tab) {
                    break :new_indent indent + 1;
                }
                break :new_indent indent + 1 + self.token_it.next().count.?;
            };

            if (new_indent < indent) break;

            const token = self.token_it.next();
            const value: *Node = value: {
                switch (token.id) {
                    .Literal => {
                        const curr_pos = self.token_it.getPos();
                        if (self.eatToken(.MapValueInd)) |_| {
                            // nested map
                            const map_node = try self.map(curr_pos, new_indent);
                            break :value &map_node.base;
                        } else {
                            // standalone (leaf) value
                            const leaf_node = try self.leaf_value();
                            break :value &leaf_node.base;
                        }
                    },
                    else => return error.Unhandled,
                }
            };
            try node.values.append(self.allocator, value);

            _ = try self.expectToken(.NewLine);
            node.end = self.token_it.getPos() - 1;
        }

        return node;
    }

    fn leaf_value(self: *Parser) ParseError!*Node.Value {
        const node = try self.allocator.create(Node.Value);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .value = self.token_it.getPos(),
        };
        node.base.tree = self.tree;
        return node;
    }

    fn eatCommentsAndSpace(self: *Parser) void {
        while (true) {
            const cur_pos = self.token_it.getPos();
            _ = self.token_it.peek() orelse return;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .Space => {},
                else => {
                    self.token_it.resetTo(cur_pos);
                    break;
                },
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

    fn expectToken(self: *Parser, id: Token.Id) ParseError!TokenIndex {
        return self.eatToken(id) orelse error.UnexpectedToken;
    }
};

test "simple doc with single map and directive" {
    const source =
        \\--- !tapi-tbd
        \\tbd-version: 4
        \\abc-version: 5
        \\...
    ;

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    try tree.parse(source);

    try testing.expectEqual(tree.docs.items.len, 1);

    const doc = tree.docs.items[0];
    try testing.expectEqual(doc.start.?, 0);
    try testing.expectEqual(doc.end.?, tree.tokens.len - 2);

    const directive = tree.tokens[doc.directive.?];
    try testing.expectEqual(directive.id, .Literal);
    try testing.expect(mem.eql(u8, "tapi-tbd", tree.source[directive.start..directive.end]));

    try testing.expect(doc.value != null);
    try testing.expectEqual(doc.value.?.tag, .map);

    const map = doc.value.?.cast(Node.Map).?;
    try testing.expectEqual(map.start.?, 4);
    try testing.expectEqual(map.end.?, 13);
    try testing.expectEqual(map.values.items.len, 2);

    {
        const entry = map.values.items[0];

        const key = tree.tokens[entry.key];
        try testing.expectEqual(key.id, .Literal);
        try testing.expect(mem.eql(u8, "tbd-version", tree.source[key.start..key.end]));

        const value = entry.value.cast(Node.Value).?;
        const value_tok = tree.tokens[value.value.?];
        try testing.expectEqual(value_tok.id, .Literal);
        try testing.expect(mem.eql(u8, "4", tree.source[value_tok.start..value_tok.end]));
    }

    {
        const entry = map.values.items[1];

        const key = tree.tokens[entry.key];
        try testing.expectEqual(key.id, .Literal);
        try testing.expect(mem.eql(u8, "abc-version", tree.source[key.start..key.end]));

        const value = entry.value.cast(Node.Value).?;
        const value_tok = tree.tokens[value.value.?];
        try testing.expectEqual(value_tok.id, .Literal);
        try testing.expect(mem.eql(u8, "5", tree.source[value_tok.start..value_tok.end]));
    }
}

// test "nested maps" {
//     const source =
//         \\---
//         \\key1:
//         \\  key1_1 : value1_1
//         \\key2   :
//         \\  key2_1  :value2_1
//         \\...
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0];
//     try testing.expectEqual(doc.start.?, 0);
//     try testing.expectEqual(doc.end.?, tree.tokens.len - 2);
//     try testing.expect(doc.directive == null);
//     try testing.expectEqual(doc.values.items.len, 2);

//     {
//         // first value: map: key1 => { key1_1 => value1 }
//         const map = doc.values.items[0].cast(Node.Map).?;
//         const key1 = tree.tokens[map.key.?];
//         try testing.expectEqual(key1.id, .Literal);
//         try testing.expect(mem.eql(u8, "key1", tree.source[key1.start..key1.end]));

//         const value1 = map.value.?.cast(Node.Map).?;
//         const key1_1 = tree.tokens[value1.key.?];
//         try testing.expectEqual(key1_1.id, .Literal);
//         try testing.expect(mem.eql(u8, "key1_1", tree.source[key1_1.start..key1_1.end]));

//         const value1_1 = value1.value.?.cast(Node.Value).?;
//         const value1_1_tok = tree.tokens[value1_1.value.?];
//         try testing.expectEqual(value1_1_tok.id, .Literal);
//         try testing.expect(mem.eql(
//             u8,
//             "value1_1",
//             tree.source[value1_1_tok.start..value1_1_tok.end],
//         ));
//     }

//     {
//         // second value: map: key2 => { key2_1 => value2 }
//         const map = doc.values.items[1].cast(Node.Map).?;
//         const key2 = tree.tokens[map.key.?];
//         try testing.expectEqual(key2.id, .Literal);
//         try testing.expect(mem.eql(u8, "key2", tree.source[key2.start..key2.end]));

//         const value2 = map.value.?.cast(Node.Map).?;
//         const key2_1 = tree.tokens[value2.key.?];
//         try testing.expectEqual(key2_1.id, .Literal);
//         try testing.expect(mem.eql(u8, "key2_1", tree.source[key2_1.start..key2_1.end]));

//         const value2_1 = value2.value.?.cast(Node.Value).?;
//         const value2_1_tok = tree.tokens[value2_1.value.?];
//         try testing.expectEqual(value2_1_tok.id, .Literal);
//         try testing.expect(mem.eql(
//             u8,
//             "value2_1",
//             tree.source[value2_1_tok.start..value2_1_tok.end],
//         ));
//     }
// }

// test "map of list of values" {
//     const source =
//         \\---
//         \\ints:
//         \\    - 0
//         \\    - 1
//         \\    - 2
//         \\...
//     ;
//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0];
//     try testing.expectEqual(doc.start.?, 0);
//     try testing.expectEqual(doc.end.?, tree.tokens.len - 2);
//     try testing.expect(doc.directive == null);
//     try testing.expectEqual(doc.values.items.len, 1);

//     const map = doc.values.items[0].cast(Node.Map).?;
//     const key = tree.tokens[map.key.?];
//     try testing.expectEqual(key.id, .Literal);
//     try testing.expect(mem.eql(u8, "ints", tree.source[key.start..key.end]));

//     const list = map.value.?.cast(Node.List).?;
//     try testing.expectEqual(list.start.?, 6);
//     try testing.expectEqual(tree.tokens[list.start.?].id, .SeqItemInd);
//     try testing.expectEqual(list.end.?, 16);
//     try testing.expectEqual(tree.tokens[list.end.?].id, .NewLine);
//     try testing.expectEqual(list.values.items.len, 3);

//     {
//         const elem = list.values.items[0].cast(Node.Value).?;
//         const value = tree.tokens[elem.value.?];
//         try testing.expectEqual(value.id, .Literal);
//         try testing.expect(mem.eql(u8, "0", tree.source[value.start..value.end]));
//     }

//     {
//         const elem = list.values.items[1].cast(Node.Value).?;
//         const value = tree.tokens[elem.value.?];
//         try testing.expectEqual(value.id, .Literal);
//         try testing.expect(mem.eql(u8, "1", tree.source[value.start..value.end]));
//     }

//     {
//         const elem = list.values.items[2].cast(Node.Value).?;
//         const value = tree.tokens[elem.value.?];
//         try testing.expectEqual(value.id, .Literal);
//         try testing.expect(mem.eql(u8, "2", tree.source[value.start..value.end]));
//     }
// }

// test "map of list of maps" {
//     const source =
//         \\---
//         \\key1:
//         \\- key2 : value2
//         \\- key3 : value3
//         \\- key4 : value4
//         \\...
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0];
//     try testing.expectEqual(doc.start.?, 0);
//     try testing.expectEqual(doc.end.?, tree.tokens.len - 2);
//     try testing.expect(doc.directive == null);
//     try testing.expectEqual(doc.values.items.len, 1);

//     const map = doc.values.items[0].cast(Node.Map).?;
//     const key = tree.tokens[map.key.?];
//     try testing.expectEqual(key.id, .Literal);
//     try testing.expect(mem.eql(u8, "key1", tree.source[key.start..key.end]));

//     const list = map.value.?.cast(Node.List).?;
//     try testing.expectEqual(list.start.?, 5);
//     try testing.expectEqual(tree.tokens[list.start.?].id, .SeqItemInd);
//     try testing.expectEqual(list.end.?, 25);
//     try testing.expectEqual(tree.tokens[list.end.?].id, .NewLine);
//     try testing.expectEqual(list.values.items.len, 3);

//     {
//         const elem = list.values.items[0].cast(Node.Map).?;
//         const key_tok = tree.tokens[elem.key.?];
//         try testing.expectEqual(key_tok.id, .Literal);
//         try testing.expect(mem.eql(u8, "key2", tree.source[key_tok.start..key_tok.end]));

//         const value = elem.value.?.cast(Node.Value).?;
//         const value_tok = tree.tokens[value.value.?];
//         try testing.expectEqual(value_tok.id, .Literal);
//         try testing.expect(mem.eql(u8, "value2", tree.source[value_tok.start..value_tok.end]));
//     }

//     {
//         const elem = list.values.items[1].cast(Node.Map).?;
//         const key_tok = tree.tokens[elem.key.?];
//         try testing.expectEqual(key_tok.id, .Literal);
//         try testing.expect(mem.eql(u8, "key3", tree.source[key_tok.start..key_tok.end]));

//         const value = elem.value.?.cast(Node.Value).?;
//         const value_tok = tree.tokens[value.value.?];
//         try testing.expectEqual(value_tok.id, .Literal);
//         try testing.expect(mem.eql(u8, "value3", tree.source[value_tok.start..value_tok.end]));
//     }

//     {
//         const elem = list.values.items[2].cast(Node.Map).?;
//         const key_tok = tree.tokens[elem.key.?];
//         try testing.expectEqual(key_tok.id, .Literal);
//         try testing.expect(mem.eql(u8, "key4", tree.source[key_tok.start..key_tok.end]));

//         const value = elem.value.?.cast(Node.Value).?;
//         const value_tok = tree.tokens[value.value.?];
//         try testing.expectEqual(value_tok.id, .Literal);
//         try testing.expect(mem.eql(u8, "value4", tree.source[value_tok.start..value_tok.end]));
//     }
// }
