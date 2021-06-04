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

        try parser.scopes.append(self.allocator, .{
            .indent = 0,
        });

        while (true) {
            const curr_pos = parser.token_it.pos;
            const next = parser.token_it.peek() orelse break;
            if (next.id == .Eof) {
                _ = parser.token_it.next();
                break;
            }

            const doc = try parser.doc(curr_pos);
            try self.docs.append(self.allocator, doc);
        }
    }
};

const Parser = struct {
    allocator: *Allocator,
    tree: *Tree,
    token_it: *TokenIterator,
    scopes: std.ArrayListUnmanaged(Scope) = .{},

    const Scope = struct {
        indent: usize,
    };

    const ParseError = error{
        MalformedYaml,
        NestedDocuments,
        UnexpectedTag,
        UnexpectedEof,
        UnexpectedToken,
        Unhandled,
    } || Allocator.Error;

    fn deinit(self: *Parser) void {
        self.scopes.deinit(self.allocator);
    }

    fn doc(self: *Parser, start: TokenIndex) ParseError!*Node.Doc {
        const node = try self.allocator.create(Node.Doc);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);

        log.debug("Doc start: {}, {}", .{ start, self.tree.tokens[start] });

        const explicit_doc: bool = if (self.eatToken(.DocStart)) |_| explicit_doc: {
            if (self.eatToken(.Tag)) |_| {
                node.directive = try self.expectToken(.Literal);
            }
            _ = try self.expectToken(.NewLine);
            break :explicit_doc true;
        } else false;

        while (true) {
            const pos = self.token_it.pos;
            const token = self.token_it.next();

            log.debug("Next token: {}, {}", .{ pos, token });

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
                    const map_node = try self.map(pos);
                    node.value = &map_node.base;
                },
                .SeqItemInd => {
                    const list_node = try self.list(pos);
                    node.value = &list_node.base;
                },
                .DocEnd => {
                    if (explicit_doc) break;
                    return error.UnexpectedToken;
                },
                .Eof => {
                    if (!explicit_doc) break;
                    return error.UnexpectedEof;
                },
                else => {},
            }
        }

        node.end = self.token_it.pos - 1;

        log.debug("Doc end: {}, {}", .{ node.end.?, self.tree.tokens[node.end.?] });

        return node;
    }

    fn map(self: *Parser, start: TokenIndex) ParseError!*Node.Map {
        const node = try self.allocator.create(Node.Map);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);

        log.debug("Map start: {}, {}", .{ start, self.tree.tokens[start] });
        log.debug("Current scope: {}", .{self.scopes.items[self.scopes.items.len - 1]});

        while (true) {
            // Parse key.
            const key_pos = self.token_it.pos;
            const key = self.token_it.next();
            switch (key.id) {
                .Literal => {},
                .NewLine, .DocEnd, .Eof => {
                    self.token_it.seekBy(-1);
                    break;
                },
                else => {
                    // TODO bubble up error.
                    log.err("{}", .{key});
                    return error.UnexpectedToken;
                },
            }

            log.debug("Map key: {}, '{s}'", .{ key, self.tree.source[key.start..key.end] });

            // Separator
            _ = try self.expectToken(.MapValueInd);
            self.eatCommentsAndSpace();

            // Parse value.
            const value: *Node = value: {
                if (self.eatToken(.NewLine)) |_| {
                    // Explicit, complex value such as list or map.
                    try self.openScope();
                    const value_pos = self.token_it.pos;
                    const value = self.token_it.next();
                    switch (value.id) {
                        .Literal => {
                            // Assume nested map.
                            const map_node = try self.map(value_pos);
                            break :value &map_node.base;
                        },
                        .SeqItemInd => {
                            // Assume list of values.
                            const list_node = try self.list(value_pos);
                            break :value &list_node.base;
                        },
                        else => return error.Unhandled,
                    }
                } else {
                    const value_pos = self.token_it.pos;
                    const value = self.token_it.next();
                    switch (value.id) {
                        .Literal => {
                            // Assume leaf value.
                            const leaf_node = try self.leaf_value(value_pos);
                            break :value &leaf_node.base;
                        },
                        else => return error.Unhandled,
                    }
                }
            };
            log.debug("Map value: {}", .{value});

            try node.values.append(self.allocator, .{
                .key = key_pos,
                .value = value,
            });

            if (self.eatToken(.NewLine)) |_| {
                if (try self.closeScope()) {
                    break;
                }
            }
        }

        node.end = self.token_it.pos - 1;

        log.debug("Map end: {}, {}", .{ node.end.?, self.tree.tokens[node.end.?] });

        return node;
    }

    fn list(self: *Parser, start: TokenIndex) ParseError!*Node.List {
        const node = try self.allocator.create(Node.List);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);

        log.debug("List start: {}, {}", .{ start, self.tree.tokens[start] });
        log.debug("Current scope: {}", .{self.scopes.items[self.scopes.items.len - 1]});

        while (true) {
            _ = self.eatToken(.SeqItemInd) orelse {
                _ = try self.closeScope();
                break;
            };

            const pos = self.token_it.pos;
            const token = self.token_it.next();
            const value: *Node = value: {
                switch (token.id) {
                    .Literal => {
                        if (self.eatToken(.MapValueInd)) |_| {
                            if (self.eatToken(.NewLine)) |_| {
                                try self.openScope();
                            }
                            // nested map
                            const map_node = try self.map(pos);
                            break :value &map_node.base;
                        } else {
                            // standalone (leaf) value
                            const leaf_node = try self.leaf_value(pos);
                            break :value &leaf_node.base;
                        }
                    },
                    else => return error.Unhandled,
                }
            };
            try node.values.append(self.allocator, value);

            _ = try self.expectToken(.NewLine);
        }

        node.end = self.token_it.pos - 1;

        log.debug("List end: {}, {}", .{ node.end.?, self.tree.tokens[node.end.?] });

        return node;
    }

    fn leaf_value(self: *Parser, start: TokenIndex) ParseError!*Node.Value {
        const node = try self.allocator.create(Node.Value);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .value = start,
        };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);
        const token = self.token_it.next();

        log.debug("Leaf value: {}, '{s}'", .{ token, self.tree.source[token.start..token.end] });

        return node;
    }

    fn openScope(self: *Parser) !void {
        const peek = self.token_it.peek() orelse return error.UnexpectedEof;
        if (peek.id != .Space and peek.id != .Tab) {
            return error.UnexpectedToken;
        }
        const indent = self.token_it.next().count.?;
        const prev_scope = self.scopes.items[self.scopes.items.len - 1];
        if (indent < prev_scope.indent) {
            return error.MalformedYaml;
        }

        log.debug("Opening scope...", .{});

        try self.scopes.append(self.allocator, .{
            .indent = indent,
        });
    }

    fn closeScope(self: *Parser) !bool {
        const indent = indent: {
            const peek = self.token_it.peek() orelse return error.UnexpectedEof;
            switch (peek.id) {
                .Space, .Tab => {
                    break :indent self.token_it.next().count.?;
                },
                else => {
                    break :indent 0;
                },
            }
        };

        const scope = self.scopes.items[self.scopes.items.len - 1];
        if (indent < scope.indent) {
            log.debug("Closing scope...", .{});
            _ = self.scopes.pop();
            return true;
        }

        return false;
    }

    fn eatCommentsAndSpace(self: *Parser) void {
        while (true) {
            _ = self.token_it.peek() orelse return;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .Space => {},
                else => {
                    self.token_it.seekBy(-1);
                    break;
                },
            }
        }
    }

    fn eatToken(self: *Parser, id: Token.Id) ?TokenIndex {
        while (true) {
            const pos = self.token_it.pos;
            _ = self.token_it.peek() orelse return null;
            const token = self.token_it.next();
            log.debug("{}", .{token});
            switch (token.id) {
                .Comment, .Space => continue,
                else => |next_id| if (next_id == id) {
                    return pos;
                } else {
                    self.token_it.seekTo(pos);
                    return null;
                },
            }
        }
    }

    fn expectToken(self: *Parser, id: Token.Id) ParseError!TokenIndex {
        return self.eatToken(id) orelse error.UnexpectedToken;
    }
};

test "explicit doc" {
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
    try testing.expectEqual(map.start.?, 5);
    try testing.expectEqual(map.end.?, 14);
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

test "nested maps" {
    const source =
        \\key1:
        \\  key1_1 : value1_1
        \\  key1_2 : value1_2
        \\key2   : value2
    ;

    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    try tree.parse(source);

    try testing.expectEqual(tree.docs.items.len, 1);

    const doc = tree.docs.items[0];
    try testing.expectEqual(doc.start.?, 0);
    try testing.expectEqual(doc.end.?, tree.tokens.len - 1);
    try testing.expect(doc.directive == null);

    try testing.expect(doc.value != null);
    try testing.expectEqual(doc.value.?.tag, .map);

    const map = doc.value.?.cast(Node.Map).?;
    try testing.expectEqual(map.start.?, 0);
    try testing.expectEqual(map.end.?, tree.tokens.len - 2);
    try testing.expectEqual(map.values.items.len, 2);

    {
        const entry = map.values.items[0];

        const key = tree.tokens[entry.key];
        try testing.expectEqual(key.id, .Literal);
        try testing.expect(mem.eql(u8, "key1", tree.source[key.start..key.end]));

        const nested_map = entry.value.cast(Node.Map).?;
        try testing.expectEqual(nested_map.start.?, 4);
        try testing.expectEqual(nested_map.end.?, 16);
        try testing.expectEqual(nested_map.values.items.len, 2);

        {
            const nested_entry = nested_map.values.items[0];

            const nested_key = tree.tokens[nested_entry.key];
            try testing.expectEqual(nested_key.id, .Literal);
            try testing.expect(mem.eql(
                u8,
                "key1_1",
                tree.source[nested_key.start..nested_key.end],
            ));

            const nested_value = nested_entry.value.cast(Node.Value).?;
            const nested_value_tok = tree.tokens[nested_value.value.?];
            try testing.expectEqual(nested_value_tok.id, .Literal);
            try testing.expect(mem.eql(
                u8,
                "value1_1",
                tree.source[nested_value_tok.start..nested_value_tok.end],
            ));
        }

        {
            const nested_entry = nested_map.values.items[1];

            const nested_key = tree.tokens[nested_entry.key];
            try testing.expectEqual(nested_key.id, .Literal);
            try testing.expect(mem.eql(
                u8,
                "key1_2",
                tree.source[nested_key.start..nested_key.end],
            ));

            const nested_value = nested_entry.value.cast(Node.Value).?;
            const nested_value_tok = tree.tokens[nested_value.value.?];
            try testing.expectEqual(nested_value_tok.id, .Literal);
            try testing.expect(mem.eql(
                u8,
                "value1_2",
                tree.source[nested_value_tok.start..nested_value_tok.end],
            ));
        }
    }

    {
        const entry = map.values.items[1];

        const key = tree.tokens[entry.key];
        try testing.expectEqual(key.id, .Literal);
        try testing.expect(mem.eql(u8, "key2", tree.source[key.start..key.end]));

        const value = entry.value.cast(Node.Value).?;
        const value_tok = tree.tokens[value.value.?];
        try testing.expectEqual(value_tok.id, .Literal);
        try testing.expect(mem.eql(
            u8,
            "value2",
            tree.source[value_tok.start..value_tok.end],
        ));
    }
}

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
