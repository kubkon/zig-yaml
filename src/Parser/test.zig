const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const List = Tree.List;
const Map = Tree.Map;
const Node = Tree.Node;
const Parser = @import("../Parser.zig");
const Tree = @import("../Tree.zig");

fn expectNodeScope(tree: Tree, node: Node.Index, from: usize, to: usize) !void {
    const scope = tree.nodeScope(node);
    try testing.expectEqual(from, @intFromEnum(scope.start));
    try testing.expectEqual(to, @intFromEnum(scope.end));
}

fn expectValueMapEntry(tree: Tree, entry_data: Map.Entry, exp_key: []const u8, exp_value: []const u8) !void {
    const key = tree.token(entry_data.key);
    try testing.expectEqual(key.id, .literal);
    try testing.expectEqualStrings(exp_key, tree.rawString(entry_data.key, entry_data.key));

    const maybe_value = entry_data.maybe_node;
    try testing.expect(maybe_value != .none);
    try testing.expectEqual(.value, tree.nodeTag(maybe_value.unwrap().?));

    const value = maybe_value.unwrap().?;
    const string = tree.nodeScope(value).rawString(tree);
    try testing.expectEqualStrings(exp_value, string);
}

fn expectStringValueMapEntry(tree: Tree, entry_data: Map.Entry, exp_key: []const u8, exp_value: []const u8) !void {
    const key = tree.token(entry_data.key);
    try testing.expectEqual(key.id, .literal);
    try testing.expectEqualStrings(exp_key, tree.rawString(entry_data.key, entry_data.key));

    const maybe_value = entry_data.maybe_node;
    try testing.expect(maybe_value != .none);
    try testing.expectEqual(.string_value, tree.nodeTag(maybe_value.unwrap().?));

    const value = maybe_value.unwrap().?;
    const string = tree.nodeData(value).string.slice(tree);
    try testing.expectEqualStrings(exp_value, string);
}

fn expectValueListEntry(tree: Tree, entry_data: List.Entry, exp_value: []const u8) !void {
    const value = entry_data.node;
    try testing.expectEqual(.value, tree.nodeTag(value));

    const string = tree.nodeScope(value).rawString(tree);
    try testing.expectEqualStrings(exp_value, string);
}

fn expectNestedMapListEntry(tree: Tree, list_entry_data: List.Entry, exp_key: []const u8, exp_value: []const u8) !void {
    const value = list_entry_data.node;
    try testing.expectEqual(.map_single, tree.nodeTag(value));

    const map_data = tree.nodeData(value).map;
    try expectValueMapEntry(tree, .{
        .key = map_data.key,
        .maybe_node = map_data.maybe_node,
    }, exp_key, exp_value);
}

test "explicit doc" {
    const source =
        \\--- !tapi-tbd
        \\tbd-version: 4
        \\abc-version: 5
        \\...
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try testing.expectEqual(.doc_with_directive, tree.nodeTag(doc));

    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const directive = tree.directive(doc).?;
    try testing.expectEqualStrings("tapi-tbd", directive);

    const doc_value = tree.nodeData(doc).doc_with_directive.maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_many, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 5, 14);

    const map_data = tree.extraData(Map, tree.nodeData(map).extra);
    try testing.expectEqual(2, map_data.data.map_len);

    var entry_data = tree.extraData(Map.Entry, map_data.end);
    try expectValueMapEntry(tree, entry_data.data, "tbd-version", "4");

    entry_data = tree.extraData(Map.Entry, entry_data.end);
    try expectValueMapEntry(tree, entry_data.data, "abc-version", "5");
}

test "leaf in quotes" {
    const source =
        \\key1: no quotes, comma
        \\key2: 'single quoted'
        \\key3: "double quoted"
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try testing.expectEqual(.doc, tree.nodeTag(doc));

    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_many, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 0, tree.tokens.len - 2);

    const map_data = tree.extraData(Map, tree.nodeData(map).extra);
    try testing.expectEqual(3, map_data.data.map_len);

    var entry_data = tree.extraData(Map.Entry, map_data.end);
    try expectValueMapEntry(tree, entry_data.data, "key1", "no quotes, comma");

    entry_data = tree.extraData(Map.Entry, entry_data.end);
    try expectStringValueMapEntry(tree, entry_data.data, "key2", "single quoted");

    entry_data = tree.extraData(Map.Entry, entry_data.end);
    try expectStringValueMapEntry(tree, entry_data.data, "key3", "double quoted");
}

test "nested maps" {
    const source =
        \\key1:
        \\  key1_1 : value1_1
        \\  key1_2 : value1_2
        \\key2   : value2
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try testing.expectEqual(.doc, tree.nodeTag(doc));

    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_many, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 0, tree.tokens.len - 2);

    const map_data = tree.extraData(Map, tree.nodeData(map).extra);
    try testing.expectEqual(2, map_data.data.map_len);

    var entry_data = tree.extraData(Map.Entry, map_data.end);
    {
        const key = tree.token(entry_data.data.key);
        try testing.expectEqual(key.id, .literal);
        try testing.expectEqualStrings("key1", tree.rawString(entry_data.data.key, entry_data.data.key));

        const maybe_nested_map = entry_data.data.maybe_node;
        try testing.expect(maybe_nested_map != .none);
        try testing.expectEqual(.map_many, tree.nodeTag(maybe_nested_map.unwrap().?));

        const nested_map = maybe_nested_map.unwrap().?;

        try expectNodeScope(tree, nested_map, 4, 16);

        const nested_map_data = tree.extraData(Map, tree.nodeData(nested_map).extra);
        try testing.expectEqual(2, nested_map_data.data.map_len);

        var nested_entry_data = tree.extraData(Map.Entry, nested_map_data.end);
        try expectValueMapEntry(tree, nested_entry_data.data, "key1_1", "value1_1");

        nested_entry_data = tree.extraData(Map.Entry, nested_entry_data.end);
        try expectValueMapEntry(tree, nested_entry_data.data, "key1_2", "value1_2");
    }

    entry_data = tree.extraData(Map.Entry, entry_data.end);
    try expectValueMapEntry(tree, entry_data.data, "key2", "value2");
}

test "map of list of values" {
    const source =
        \\ints:
        \\  - 0
        \\  - 1
        \\  - 2
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_single, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 0, tree.tokens.len - 2);

    const map_data = tree.nodeData(map).map;

    {
        const key = tree.token(map_data.key);
        try testing.expectEqual(key.id, .literal);
        try testing.expectEqualStrings("ints", tree.rawString(map_data.key, map_data.key));

        const maybe_nested_list = map_data.maybe_node;
        try testing.expect(maybe_nested_list != .none);
        try testing.expectEqual(.list_many, tree.nodeTag(maybe_nested_list.unwrap().?));

        const nested_list = maybe_nested_list.unwrap().?;

        try expectNodeScope(tree, nested_list, 4, tree.tokens.len - 2);

        const nested_list_data = tree.extraData(List, tree.nodeData(nested_list).extra);
        try testing.expectEqual(3, nested_list_data.data.list_len);

        var nested_entry_data = tree.extraData(List.Entry, nested_list_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "0");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "1");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "2");
    }
}

test "map of list of maps" {
    const source =
        \\key1:
        \\- key2 : value2
        \\- key3 : value3
        \\- key4 : value4
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_single, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 0, tree.tokens.len - 2);

    const map_data = tree.nodeData(map).map;

    {
        const key = tree.token(map_data.key);
        try testing.expectEqual(key.id, .literal);
        try testing.expectEqualStrings("key1", tree.rawString(map_data.key, map_data.key));

        const maybe_nested_list = map_data.maybe_node;
        try testing.expect(maybe_nested_list != .none);
        try testing.expectEqual(.list_many, tree.nodeTag(maybe_nested_list.unwrap().?));

        const nested_list = maybe_nested_list.unwrap().?;

        try expectNodeScope(tree, nested_list, 3, tree.tokens.len - 2);

        const nested_list_data = tree.extraData(List, tree.nodeData(nested_list).extra);
        try testing.expectEqual(3, nested_list_data.data.list_len);

        var nested_entry_data = tree.extraData(List.Entry, nested_list_data.end);
        try expectNestedMapListEntry(tree, nested_entry_data.data, "key2", "value2");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectNestedMapListEntry(tree, nested_entry_data.data, "key3", "value3");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectNestedMapListEntry(tree, nested_entry_data.data, "key4", "value4");
    }
}

test "map of list of maps with inner list" {
    const source =
        \\ outer:
        \\   - a: foo
        \\     fooers:
        \\       - name: inner-foo
        \\   - b: bar
        \\     fooers:
        \\       - name: inner-bar
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try expectNodeScope(tree, doc, 1, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_single, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 1, tree.tokens.len - 2);

    const map_data = tree.nodeData(map).map;

    {
        const key = tree.token(map_data.key);
        try testing.expectEqual(key.id, .literal);
        try testing.expectEqualStrings("outer", tree.rawString(map_data.key, map_data.key));

        const maybe_nested_list = map_data.maybe_node;
        try testing.expect(maybe_nested_list != .none);
        try testing.expectEqual(.list_two, tree.nodeTag(maybe_nested_list.unwrap().?));

        const nested_list = maybe_nested_list.unwrap().?;

        try expectNodeScope(tree, nested_list, 5, tree.tokens.len - 2);

        const nested_list_data = tree.nodeData(nested_list).list;

        {
            const nested_map = nested_list_data.el1;
            try testing.expectEqual(.map_many, tree.nodeTag(nested_map));

            const nested_map_data = tree.extraData(Map, tree.nodeData(nested_map).extra);
            try testing.expectEqual(2, nested_map_data.data.map_len);

            var nested_nested_entry_data = tree.extraData(Map.Entry, nested_map_data.end);
            try expectValueMapEntry(tree, nested_nested_entry_data.data, "a", "foo");

            nested_nested_entry_data = tree.extraData(Map.Entry, nested_nested_entry_data.end);
            {
                const nested_nested_map_entry = nested_nested_entry_data.data;
                const nested_nested_key = tree.token(nested_nested_map_entry.key);
                try testing.expectEqual(nested_nested_key.id, .literal);
                try testing.expectEqualStrings("fooers", tree.rawString(nested_nested_map_entry.key, nested_nested_map_entry.key));

                const nested_nested_value = nested_nested_map_entry.maybe_node;
                try testing.expect(nested_nested_value != .none);
                try testing.expectEqual(.list_one, tree.nodeTag(nested_nested_value.unwrap().?));

                const nested_nested_list = nested_nested_value.unwrap().?;
                const nested_nested_list_data = tree.nodeData(nested_nested_list).node;
                try expectNestedMapListEntry(tree, .{ .node = nested_nested_list_data }, "name", "inner-foo");
            }
        }

        {
            const nested_map = nested_list_data.el2;
            try testing.expectEqual(.map_many, tree.nodeTag(nested_map));

            const nested_map_data = tree.extraData(Map, tree.nodeData(nested_map).extra);
            try testing.expectEqual(2, nested_map_data.data.map_len);

            var nested_nested_entry_data = tree.extraData(Map.Entry, nested_map_data.end);
            try expectValueMapEntry(tree, nested_nested_entry_data.data, "b", "bar");

            nested_nested_entry_data = tree.extraData(Map.Entry, nested_nested_entry_data.end);
            {
                const nested_nested_map_entry = nested_nested_entry_data.data;
                const nested_nested_key = tree.token(nested_nested_map_entry.key);
                try testing.expectEqual(nested_nested_key.id, .literal);
                try testing.expectEqualStrings("fooers", tree.rawString(nested_nested_map_entry.key, nested_nested_map_entry.key));

                const nested_nested_value = nested_nested_map_entry.maybe_node;
                try testing.expect(nested_nested_value != .none);
                try testing.expectEqual(.list_one, tree.nodeTag(nested_nested_value.unwrap().?));

                const nested_nested_list = nested_nested_value.unwrap().?;
                const nested_nested_list_data = tree.nodeData(nested_nested_list).node;
                try expectNestedMapListEntry(tree, .{ .node = nested_nested_list_data }, "name", "inner-bar");
            }
        }
    }
}

test "list of lists" {
    const source =
        \\- [name        , hr, avg  ]
        \\- [Mark McGwire , 65, 0.278]
        \\- [Sammy Sosa   , 63, 0.288]
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.list_many, tree.nodeTag(doc_value.unwrap().?));

    const list = doc_value.unwrap().?;

    try expectNodeScope(tree, list, 0, tree.tokens.len - 2);

    const list_data = tree.extraData(List, tree.nodeData(list).extra);
    try testing.expectEqual(3, list_data.data.list_len);

    var entry_data = tree.extraData(List.Entry, list_data.end);
    {
        const nested_list = entry_data.data.node;

        try expectNodeScope(tree, nested_list, 1, 11);

        const nested_list_data = tree.extraData(List, tree.nodeData(nested_list).extra);
        try testing.expectEqual(3, nested_list_data.data.list_len);

        var nested_entry_data = tree.extraData(List.Entry, nested_list_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "name");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "hr");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "avg");
    }

    entry_data = tree.extraData(List.Entry, entry_data.end);
    {
        const nested_list = entry_data.data.node;

        try expectNodeScope(tree, nested_list, 14, 25);

        const nested_list_data = tree.extraData(List, tree.nodeData(nested_list).extra);
        try testing.expectEqual(3, nested_list_data.data.list_len);

        var nested_entry_data = tree.extraData(List.Entry, nested_list_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "Mark McGwire");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "65");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "0.278");
    }

    entry_data = tree.extraData(List.Entry, entry_data.end);
    {
        const nested_list = entry_data.data.node;

        try expectNodeScope(tree, nested_list, 28, 39);

        const nested_list_data = tree.extraData(List, tree.nodeData(nested_list).extra);
        try testing.expectEqual(3, nested_list_data.data.list_len);

        var nested_entry_data = tree.extraData(List.Entry, nested_list_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "Sammy Sosa");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "63");

        nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
        try expectValueListEntry(tree, nested_entry_data.data, "0.288");
    }
}

test "inline list" {
    const source =
        \\[name        , hr, avg  ]
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.list_many, tree.nodeTag(doc_value.unwrap().?));

    const list = doc_value.unwrap().?;

    try expectNodeScope(tree, list, 0, tree.tokens.len - 2);

    const list_data = tree.extraData(List, tree.nodeData(list).extra);
    try testing.expectEqual(3, list_data.data.list_len);

    var entry_data = tree.extraData(List.Entry, list_data.end);
    try expectValueListEntry(tree, entry_data.data, "name");

    entry_data = tree.extraData(List.Entry, entry_data.end);
    try expectValueListEntry(tree, entry_data.data, "hr");

    entry_data = tree.extraData(List.Entry, entry_data.end);
    try expectValueListEntry(tree, entry_data.data, "avg");
}

test "inline list as mapping value" {
    const source =
        \\key : [
        \\        name        ,
        \\        hr, avg  ]
    ;

    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);

    var tree = try parser.toOwnedTree(testing.allocator);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try expectNodeScope(tree, doc, 0, tree.tokens.len - 2);

    const doc_value = tree.nodeData(doc).maybe_node;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map_single, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;

    try expectNodeScope(tree, map, 0, tree.tokens.len - 2);

    const map_data = tree.nodeData(map).map;

    const key = tree.token(map_data.key);
    try testing.expectEqual(key.id, .literal);
    try testing.expectEqualStrings("key", tree.rawString(map_data.key, map_data.key));

    const maybe_nested_list = map_data.maybe_node;
    try testing.expect(maybe_nested_list != .none);
    try testing.expectEqual(.list_many, tree.nodeTag(maybe_nested_list.unwrap().?));

    const nested_list = maybe_nested_list.unwrap().?;

    try expectNodeScope(tree, nested_list, 4, tree.tokens.len - 2);

    const nested_list_data = tree.extraData(List, tree.nodeData(nested_list).extra);
    try testing.expectEqual(3, nested_list_data.data.list_len);

    var nested_entry_data = tree.extraData(List.Entry, nested_list_data.end);
    try expectValueListEntry(tree, nested_entry_data.data, "name");

    nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
    try expectValueListEntry(tree, nested_entry_data.data, "hr");

    nested_entry_data = tree.extraData(List.Entry, nested_entry_data.end);
    try expectValueListEntry(tree, nested_entry_data.data, "avg");
}

fn parseSuccess(comptime source: []const u8) !void {
    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try parser.parse(testing.allocator);
}

fn parseError(comptime source: []const u8, err: Parser.ParseError) !void {
    var parser: Parser = .{ .source = source };
    defer parser.deinit(testing.allocator);
    try testing.expectError(err, parser.parse(testing.allocator));
}

fn parseError2(source: []const u8, comptime format: []const u8, args: anytype) !void {
    var parser = try Parser.init(testing.allocator, source);
    defer parser.deinit(testing.allocator);

    const res = parser.parse(testing.allocator);
    try testing.expectError(error.ParseFailure, res);

    var bundle = try parser.errors.toOwnedBundle("");
    defer bundle.deinit(testing.allocator);
    try testing.expect(bundle.errorMessageCount() > 0);

    var given: std.ArrayListUnmanaged(u8) = .empty;
    defer given.deinit(testing.allocator);
    try bundle.renderToWriter(.{ .ttyconf = .no_color }, given.writer(testing.allocator));

    const expected = try std.fmt.allocPrint(testing.allocator, format, args);
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, given.items);
}

test "empty doc with spaces and comments" {
    try parseSuccess(
        \\
        \\
        \\   # this is a comment in a weird place
        \\# and this one is too
    );
}

test "comment between --- and ! in document start" {
    try parseError(
        \\--- # what is it?
        \\!
    , error.UnexpectedToken);
}

test "correct doc start with tag" {
    try parseSuccess(
        \\--- !some-tag
        \\
    );
}

test "doc close without explicit doc open" {
    try parseError(
        \\
        \\
        \\# something cool
        \\...
    , error.UnexpectedToken);
}

test "doc open and close are ok" {
    try parseSuccess(
        \\---
        \\# first doc
        \\
        \\
        \\---
        \\# second doc
        \\
        \\
        \\...
    );
}

test "doc with a single string is ok" {
    try parseSuccess(
        \\a string of some sort
        \\
    );
}

test "explicit doc with a single string is ok" {
    try parseSuccess(
        \\--- !anchor
        \\# nothing to see here except one string
        \\  # not a lot to go on with
        \\a single string
        \\...
    );
}

test "doc with two string is bad" {
    try parseError(
        \\first
        \\second
        \\# this should fail already
    , error.UnexpectedToken);
}

test "single quote string can have new lines" {
    try parseSuccess(
        \\'what is this
        \\ thing?'
    );
}

test "single quote string on one line is fine" {
    try parseSuccess(
        \\'here''s an apostrophe'
    );
}

test "double quote string can have new lines" {
    try parseSuccess(
        \\"what is this
        \\ thing?"
    );
}

test "double quote string on one line is fine" {
    try parseSuccess(
        \\"a newline\nand a\ttab"
    );
}

test "map with key and value literals" {
    try parseSuccess(
        \\key1: val1
        \\key2 : val2
    );
}

test "map of maps" {
    try parseSuccess(
        \\
        \\# the first key
        \\key1:
        \\  # the first subkey
        \\  key1_1: 0
        \\  key1_2: 1
        \\# the second key
        \\key2:
        \\  key2_1: -1
        \\  key2_2: -2
        \\# the end of map
    );
}

test "map value indicator needs to be on the same line" {
    try parseError(
        \\a
        \\  : b
    , error.UnexpectedToken);
}

test "value needs to be indented" {
    try parseError(
        \\a:
        \\b
    , error.MalformedYaml);
}

test "comment between a key and a value is fine" {
    try parseSuccess(
        \\a:
        \\  # this is a value
        \\  b
    );
}

test "simple list" {
    try parseSuccess(
        \\# first el
        \\- a
        \\# second el
        \\-  b
        \\# third el
        \\-   c
    );
}

test "list indentation matters" {
    try parseError(
        \\  - a
        \\- b
    , error.UnexpectedToken);

    try parseSuccess(
        \\- a
        \\  - b
    );
}

test "unindented list is fine too" {
    try parseSuccess(
        \\a:
        \\- 0
        \\- 1
    );
}

test "empty values in a map" {
    try parseSuccess(
        \\a:
        \\b:
        \\- 0
    );
}

test "weirdly nested map of maps of lists" {
    try parseSuccess(
        \\a:
        \\ b:
        \\  - 0
        \\  - 1
    );
}

test "square brackets denote a list" {
    try parseSuccess(
        \\[ a,
        \\  b, c ]
    );
}

test "empty list" {
    try parseSuccess(
        \\[ ]
    );
}

test "empty map" {
    try parseSuccess(
        \\a:
        \\  b: {}
        \\  c: { }
    );
}

test "comment within a bracketed list is an error" {
    try parseError(
        \\[ # something
        \\]
    , error.MalformedYaml);
}

test "mixed ints with floats in a list" {
    try parseSuccess(
        \\[0, 1.0]
    );
}

test "expect end of document" {
    try parseError2(
        \\  key1: value1
        \\key2: value2
    ,
        \\(memory):2:1: error: expected end of document
        \\key2: value2
        \\^~~~~~~~~~~~
        \\
    , .{});
}

test "expect map separator" {
    try parseError2(
        \\key1: value1
        \\key2
    ,
        \\(memory):2:5: error: expected map separator ':'
        \\key2
        \\~~~~^
        \\
    , .{});
}
