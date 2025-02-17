const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const parse = @import("../parse.zig");

const Node = parse.Node;
const Parser = parse.Parser;
const Tree = parse.Tree;

fn expectMapEntryWithStringValue(
    tree: Tree,
    entry_data: parse.Map.Entry,
    exp_key: []const u8,
    exp_value: []const u8,
) !void {
    const key = tree.getToken(entry_data.key);
    try testing.expectEqual(key.id, .literal);
    try testing.expectEqualStrings(exp_key, tree.getRaw(entry_data.key, entry_data.key));

    const maybe_value = entry_data.value;
    try testing.expect(maybe_value != .none);
    try testing.expectEqual(.value, tree.nodeTag(maybe_value.unwrap().?));

    const value = maybe_value.unwrap().?;
    const string = tree.nodeData(value).string.slice(tree);
    try testing.expectEqualStrings(exp_value, string);
}

test "explicit doc" {
    const source =
        \\--- !tapi-tbd
        \\tbd-version: 4
        \\abc-version: 5
        \\...
    ;

    var parser: Parser = .{ .allocator = testing.allocator, .source = source };
    defer parser.deinit();
    try parser.parse();

    var tree = try parser.toOwnedTree();
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try testing.expectEqual(.doc_with_directive, tree.nodeTag(doc));

    const doc_scope = parser.nodes_scopes.get(doc).?;
    try testing.expectEqual(0, @intFromEnum(doc_scope.start));
    try testing.expectEqual(tree.tokens.len - 2, @intFromEnum(doc_scope.end));

    const directive = tree.getDirective(doc).?;
    try testing.expectEqualStrings("tapi-tbd", directive);

    const doc_value = tree.nodeData(doc).doc_with_directive.value;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;
    const map_scope = parser.nodes_scopes.get(map).?;
    try testing.expectEqual(5, @intFromEnum(map_scope.start));
    try testing.expectEqual(14, @intFromEnum(map_scope.end));

    const map_data = tree.extraData(parse.Map, tree.nodeData(map).extra);
    try testing.expectEqual(2, map_data.data.map_len);

    var entry_data = tree.extraData(parse.Map.Entry, map_data.end);
    try expectMapEntryWithStringValue(tree, entry_data.data, "tbd-version", "4");

    entry_data = tree.extraData(parse.Map.Entry, entry_data.end);
    try expectMapEntryWithStringValue(tree, entry_data.data, "abc-version", "5");
}

test "leaf in quotes" {
    const source =
        \\key1: no quotes, comma
        \\key2: 'single quoted'
        \\key3: "double quoted"
    ;

    var parser: Parser = .{ .allocator = testing.allocator, .source = source };
    defer parser.deinit();
    try parser.parse();

    var tree = try parser.toOwnedTree();
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try testing.expectEqual(.doc, tree.nodeTag(doc));

    const doc_scope = parser.nodes_scopes.get(doc).?;
    try testing.expectEqual(0, @intFromEnum(doc_scope.start));
    try testing.expectEqual(tree.tokens.len - 2, @intFromEnum(doc_scope.end));

    const doc_value = tree.nodeData(doc).value;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;
    const map_scope = parser.nodes_scopes.get(map).?;
    try testing.expectEqual(0, @intFromEnum(map_scope.start));
    try testing.expectEqual(tree.tokens.len - 2, @intFromEnum(map_scope.end));

    const map_data = tree.extraData(parse.Map, tree.nodeData(map).extra);
    try testing.expectEqual(3, map_data.data.map_len);

    var entry_data = tree.extraData(parse.Map.Entry, map_data.end);
    try expectMapEntryWithStringValue(tree, entry_data.data, "key1", "no quotes, comma");

    entry_data = tree.extraData(parse.Map.Entry, entry_data.end);
    try expectMapEntryWithStringValue(tree, entry_data.data, "key2", "single quoted");

    entry_data = tree.extraData(parse.Map.Entry, entry_data.end);
    try expectMapEntryWithStringValue(tree, entry_data.data, "key3", "double quoted");
}

test "nested maps" {
    const source =
        \\key1:
        \\  key1_1 : value1_1
        \\  key1_2 : value1_2
        \\key2   : value2
    ;

    var parser: Parser = .{ .allocator = testing.allocator, .source = source };
    defer parser.deinit();
    try parser.parse();

    var tree = try parser.toOwnedTree();
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(1, tree.docs.len);

    const doc = tree.docs[0];
    try testing.expectEqual(.doc, tree.nodeTag(doc));

    const doc_scope = parser.nodes_scopes.get(doc).?;
    try testing.expectEqual(0, @intFromEnum(doc_scope.start));
    try testing.expectEqual(tree.tokens.len - 2, @intFromEnum(doc_scope.end));

    const doc_value = tree.nodeData(doc).value;
    try testing.expect(doc_value != .none);
    try testing.expectEqual(.map, tree.nodeTag(doc_value.unwrap().?));

    const map = doc_value.unwrap().?;
    const map_scope = parser.nodes_scopes.get(map).?;
    try testing.expectEqual(0, @intFromEnum(map_scope.start));
    try testing.expectEqual(tree.tokens.len - 2, @intFromEnum(map_scope.end));

    const map_data = tree.extraData(parse.Map, tree.nodeData(map).extra);
    try testing.expectEqual(2, map_data.data.map_len);

    var entry_data = tree.extraData(parse.Map.Entry, map_data.end);
    {
        const key = tree.getToken(entry_data.data.key);
        try testing.expectEqual(key.id, .literal);
        try testing.expectEqualStrings("key1", tree.getRaw(entry_data.data.key, entry_data.data.key));

        const maybe_nested_map = entry_data.data.value;
        try testing.expect(maybe_nested_map != .none);
        try testing.expectEqual(.map, tree.nodeTag(maybe_nested_map.unwrap().?));

        const nested_map = maybe_nested_map.unwrap().?;
        const nested_map_scope = parser.nodes_scopes.get(nested_map).?;
        try testing.expectEqual(4, @intFromEnum(nested_map_scope.start));
        try testing.expectEqual(16, @intFromEnum(nested_map_scope.end));

        const nested_map_data = tree.extraData(parse.Map, tree.nodeData(nested_map).extra);
        try testing.expectEqual(2, nested_map_data.data.map_len);

        var nested_entry_data = tree.extraData(parse.Map.Entry, nested_map_data.end);
        try expectMapEntryWithStringValue(tree, nested_entry_data.data, "key1_1", "value1_1");

        nested_entry_data = tree.extraData(parse.Map.Entry, nested_entry_data.end);
        try expectMapEntryWithStringValue(tree, nested_entry_data.data, "key1_2", "value1_2");
    }

    entry_data = tree.extraData(parse.Map.Entry, entry_data.end);
    try expectMapEntryWithStringValue(tree, entry_data.data, "key2", "value2");
}

// test "map of list of values" {
//     const source =
//         \\ints:
//         \\  - 0
//         \\  - 1
//         \\  - 2
//     ;
//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0].cast(Node.Doc).?;
//     try testing.expectEqual(@intFromEnum(doc.base.start), 0);
//     try testing.expectEqual(@intFromEnum(doc.base.end), tree.tokens.len - 2);

//     try testing.expect(doc.value != null);
//     try testing.expectEqual(doc.value.?.tag, .map);

//     const map = doc.value.?.cast(Node.Map).?;
//     try testing.expectEqual(@intFromEnum(map.base.start), 0);
//     try testing.expectEqual(@intFromEnum(map.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(map.values.items.len, 1);

//     const entry = map.values.items[0];
//     const key = tree.getToken(entry.key);
//     try testing.expectEqual(key.id, .literal);
//     try testing.expectEqualStrings("ints", tree.source[key.loc.start..key.loc.end]);

//     const value = entry.value.?.cast(Node.List).?;
//     try testing.expectEqual(@intFromEnum(value.base.start), 4);
//     try testing.expectEqual(@intFromEnum(value.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(value.values.items.len, 3);

//     {
//         const elem = value.values.items[0].cast(Node.Value).?;
//         const leaf = tree.getToken(elem.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("0", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         const elem = value.values.items[1].cast(Node.Value).?;
//         const leaf = tree.getToken(elem.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("1", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         const elem = value.values.items[2].cast(Node.Value).?;
//         const leaf = tree.getToken(elem.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("2", tree.source[leaf.loc.start..leaf.loc.end]);
//     }
// }

// test "map of list of maps" {
//     const source =
//         \\key1:
//         \\- key2 : value2
//         \\- key3 : value3
//         \\- key4 : value4
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0].cast(Node.Doc).?;
//     try testing.expectEqual(@intFromEnum(doc.base.start), 0);
//     try testing.expectEqual(@intFromEnum(doc.base.end), tree.tokens.len - 2);

//     try testing.expect(doc.value != null);
//     try testing.expectEqual(doc.value.?.tag, .map);

//     const map = doc.value.?.cast(Node.Map).?;
//     try testing.expectEqual(@intFromEnum(map.base.start), 0);
//     try testing.expectEqual(@intFromEnum(map.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(map.values.items.len, 1);

//     const entry = map.values.items[0];
//     const key = tree.getToken(entry.key);
//     try testing.expectEqual(key.id, .literal);
//     try testing.expectEqualStrings("key1", tree.source[key.loc.start..key.loc.end]);

//     const value = entry.value.?.cast(Node.List).?;
//     try testing.expectEqual(@intFromEnum(value.base.start), 3);
//     try testing.expectEqual(@intFromEnum(value.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(value.values.items.len, 3);

//     {
//         const elem = value.values.items[0].cast(Node.Map).?;
//         const nested = elem.values.items[0];
//         const nested_key = tree.getToken(nested.key);
//         try testing.expectEqual(nested_key.id, .literal);
//         try testing.expectEqualStrings("key2", tree.source[nested_key.loc.start..nested_key.loc.end]);

//         const nested_v = nested.value.?.cast(Node.Value).?;
//         const leaf = tree.getToken(nested_v.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("value2", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         const elem = value.values.items[1].cast(Node.Map).?;
//         const nested = elem.values.items[0];
//         const nested_key = tree.getToken(nested.key);
//         try testing.expectEqual(nested_key.id, .literal);
//         try testing.expectEqualStrings("key3", tree.source[nested_key.loc.start..nested_key.loc.end]);

//         const nested_v = nested.value.?.cast(Node.Value).?;
//         const leaf = tree.getToken(nested_v.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("value3", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         const elem = value.values.items[2].cast(Node.Map).?;
//         const nested = elem.values.items[0];
//         const nested_key = tree.getToken(nested.key);
//         try testing.expectEqual(nested_key.id, .literal);
//         try testing.expectEqualStrings("key4", tree.source[nested_key.loc.start..nested_key.loc.end]);

//         const nested_v = nested.value.?.cast(Node.Value).?;
//         const leaf = tree.getToken(nested_v.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("value4", tree.source[leaf.loc.start..leaf.loc.end]);
//     }
// }

// test "map of list of maps with inner list" {
//     const source =
//         \\ outer:
//         \\   - a: foo
//         \\     fooers:
//         \\       - name: inner-foo
//         \\   - b: bar
//         \\     fooers:
//         \\       - name: inner-bar
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0].cast(Node.Doc).?;
//     try testing.expectEqual(@intFromEnum(doc.base.start), 1);
//     try testing.expectEqual(@intFromEnum(doc.base.end), tree.tokens.len - 2);

//     try testing.expect(doc.value != null);
//     try testing.expectEqual(doc.value.?.tag, .map);

//     const map = doc.value.?.cast(Node.Map).?;
//     try testing.expectEqual(@intFromEnum(map.base.start), 1);
//     try testing.expectEqual(@intFromEnum(map.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(map.values.items.len, 1);

//     const entry = map.values.items[0];
//     const key = tree.getToken(entry.key);
//     try testing.expectEqual(key.id, .literal);
//     try testing.expectEqualStrings("outer", tree.source[key.loc.start..key.loc.end]);

//     const value = entry.value.?.cast(Node.List).?;
//     try testing.expectEqual(@intFromEnum(value.base.start), 5);
//     try testing.expectEqual(@intFromEnum(value.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(value.values.items.len, 2);

//     {
//         const elem = value.values.items[0].cast(Node.Map).?;
//         const nested = elem.values.items[0];
//         const nested_key = tree.getToken(nested.key);
//         try testing.expectEqual(nested_key.id, .literal);
//         try testing.expectEqualStrings("a", tree.source[nested_key.loc.start..nested_key.loc.end]);

//         const nested_v = nested.value.?.cast(Node.Value).?;
//         const leaf = tree.getToken(nested_v.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("foo", tree.source[leaf.loc.start..leaf.loc.end]);

//         {
//             const elem_with_inner_list = elem.values.items[1];
//             const elem_with_inner_list_key = tree.getToken(elem_with_inner_list.key);
//             try testing.expectEqual(elem_with_inner_list_key.id, .literal);
//             try testing.expectEqualStrings("fooers", tree.source[elem_with_inner_list_key.loc.start..elem_with_inner_list_key.loc.end]);

//             const elem_with_inner_list_value = elem_with_inner_list.value.?.cast(Node.List).?;
//             try testing.expectEqual(elem_with_inner_list_value.values.items.len, 1);

//             const innermost_entries = elem_with_inner_list_value.values.items[0].cast(Node.Map).?;
//             const innermost_elem = innermost_entries.values.items[0];
//             const innermost_key = tree.getToken(innermost_elem.key);
//             try testing.expectEqual(innermost_key.id, .literal);
//             try testing.expectEqualStrings("name", tree.source[innermost_key.loc.start..innermost_key.loc.end]);

//             const innermost_value = innermost_elem.value.?.cast(Node.Value).?;
//             const innermost_leaf = tree.getToken(innermost_value.base.start);
//             try testing.expectEqual(innermost_leaf.id, .literal);
//             try testing.expectEqualStrings("inner-foo", tree.source[innermost_leaf.loc.start..innermost_leaf.loc.end]);
//         }
//     }

//     {
//         const elem = value.values.items[1].cast(Node.Map).?;
//         const nested = elem.values.items[0];
//         const nested_key = tree.getToken(nested.key);
//         try testing.expectEqual(nested_key.id, .literal);
//         try testing.expectEqualStrings("b", tree.source[nested_key.loc.start..nested_key.loc.end]);

//         const nested_v = nested.value.?.cast(Node.Value).?;
//         const leaf = tree.getToken(nested_v.base.start);
//         try testing.expectEqual(leaf.id, .literal);
//         try testing.expectEqualStrings("bar", tree.source[leaf.loc.start..leaf.loc.end]);

//         {
//             const elem_with_inner_list = elem.values.items[1];
//             const elem_with_inner_list_key = tree.getToken(elem_with_inner_list.key);
//             try testing.expectEqual(elem_with_inner_list_key.id, .literal);
//             try testing.expectEqualStrings("fooers", tree.source[elem_with_inner_list_key.loc.start..elem_with_inner_list_key.loc.end]);

//             const elem_with_inner_list_value = elem_with_inner_list.value.?.cast(Node.List).?;
//             try testing.expectEqual(elem_with_inner_list_value.values.items.len, 1);

//             const innermost_entries = elem_with_inner_list_value.values.items[0].cast(Node.Map).?;
//             const innermost_elem = innermost_entries.values.items[0];
//             const innermost_key = tree.getToken(innermost_elem.key);
//             try testing.expectEqual(innermost_key.id, .literal);
//             try testing.expectEqualStrings("name", tree.source[innermost_key.loc.start..innermost_key.loc.end]);

//             const innermost_value = innermost_elem.value.?.cast(Node.Value).?;
//             const innermost_leaf = tree.getToken(innermost_value.base.start);
//             try testing.expectEqual(innermost_leaf.id, .literal);
//             try testing.expectEqualStrings("inner-bar", tree.source[innermost_leaf.loc.start..innermost_leaf.loc.end]);
//         }
//     }
// }

// test "list of lists" {
//     const source =
//         \\- [name        , hr, avg  ]
//         \\- [Mark McGwire , 65, 0.278]
//         \\- [Sammy Sosa   , 63, 0.288]
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0].cast(Node.Doc).?;
//     try testing.expectEqual(@intFromEnum(doc.base.start), 0);
//     try testing.expectEqual(@intFromEnum(doc.base.end), tree.tokens.len - 2);

//     try testing.expect(doc.value != null);
//     try testing.expectEqual(doc.value.?.tag, .list);

//     const list = doc.value.?.cast(Node.List).?;
//     try testing.expectEqual(@intFromEnum(list.base.start), 0);
//     try testing.expectEqual(@intFromEnum(list.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(list.values.items.len, 3);

//     {
//         try testing.expectEqual(list.values.items[0].tag, .list);
//         const nested = list.values.items[0].cast(Node.List).?;
//         try testing.expectEqual(nested.values.items.len, 3);

//         {
//             try testing.expectEqual(nested.values.items[0].tag, .value);
//             const value = nested.values.items[0].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("name", tree.source[leaf.loc.start..leaf.loc.end]);
//         }

//         {
//             try testing.expectEqual(nested.values.items[1].tag, .value);
//             const value = nested.values.items[1].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("hr", tree.source[leaf.loc.start..leaf.loc.end]);
//         }

//         {
//             try testing.expectEqual(nested.values.items[2].tag, .value);
//             const value = nested.values.items[2].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("avg", tree.source[leaf.loc.start..leaf.loc.end]);
//         }
//     }

//     {
//         try testing.expectEqual(list.values.items[1].tag, .list);
//         const nested = list.values.items[1].cast(Node.List).?;
//         try testing.expectEqual(nested.values.items.len, 3);

//         {
//             try testing.expectEqual(nested.values.items[0].tag, .value);
//             const value = nested.values.items[0].cast(Node.Value).?;
//             const start = tree.getToken(value.base.start);
//             const end = tree.getToken(value.base.end);
//             try testing.expectEqualStrings("Mark McGwire", tree.source[start.loc.start..end.loc.end]);
//         }

//         {
//             try testing.expectEqual(nested.values.items[1].tag, .value);
//             const value = nested.values.items[1].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("65", tree.source[leaf.loc.start..leaf.loc.end]);
//         }

//         {
//             try testing.expectEqual(nested.values.items[2].tag, .value);
//             const value = nested.values.items[2].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("0.278", tree.source[leaf.loc.start..leaf.loc.end]);
//         }
//     }

//     {
//         try testing.expectEqual(list.values.items[2].tag, .list);
//         const nested = list.values.items[2].cast(Node.List).?;
//         try testing.expectEqual(nested.values.items.len, 3);

//         {
//             try testing.expectEqual(nested.values.items[0].tag, .value);
//             const value = nested.values.items[0].cast(Node.Value).?;
//             const start = tree.getToken(value.base.start);
//             const end = tree.getToken(value.base.end);
//             try testing.expectEqualStrings("Sammy Sosa", tree.source[start.loc.start..end.loc.end]);
//         }

//         {
//             try testing.expectEqual(nested.values.items[1].tag, .value);
//             const value = nested.values.items[1].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("63", tree.source[leaf.loc.start..leaf.loc.end]);
//         }

//         {
//             try testing.expectEqual(nested.values.items[2].tag, .value);
//             const value = nested.values.items[2].cast(Node.Value).?;
//             const leaf = tree.getToken(value.base.start);
//             try testing.expectEqualStrings("0.288", tree.source[leaf.loc.start..leaf.loc.end]);
//         }
//     }
// }

// test "inline list" {
//     const source =
//         \\[name        , hr, avg  ]
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0].cast(Node.Doc).?;
//     try testing.expectEqual(@intFromEnum(doc.base.start), 0);
//     try testing.expectEqual(@intFromEnum(doc.base.end), tree.tokens.len - 2);

//     try testing.expect(doc.value != null);
//     try testing.expectEqual(doc.value.?.tag, .list);

//     const list = doc.value.?.cast(Node.List).?;
//     try testing.expectEqual(@intFromEnum(list.base.start), 0);
//     try testing.expectEqual(@intFromEnum(list.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(list.values.items.len, 3);

//     {
//         try testing.expectEqual(list.values.items[0].tag, .value);
//         const value = list.values.items[0].cast(Node.Value).?;
//         const leaf = tree.getToken(value.base.start);
//         try testing.expectEqualStrings("name", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         try testing.expectEqual(list.values.items[1].tag, .value);
//         const value = list.values.items[1].cast(Node.Value).?;
//         const leaf = tree.getToken(value.base.start);
//         try testing.expectEqualStrings("hr", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         try testing.expectEqual(list.values.items[2].tag, .value);
//         const value = list.values.items[2].cast(Node.Value).?;
//         const leaf = tree.getToken(value.base.start);
//         try testing.expectEqualStrings("avg", tree.source[leaf.loc.start..leaf.loc.end]);
//     }
// }

// test "inline list as mapping value" {
//     const source =
//         \\key : [
//         \\        name        ,
//         \\        hr, avg  ]
//     ;

//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);

//     try testing.expectEqual(tree.docs.items.len, 1);

//     const doc = tree.docs.items[0].cast(Node.Doc).?;
//     try testing.expectEqual(@intFromEnum(doc.base.start), 0);
//     try testing.expectEqual(@intFromEnum(doc.base.end), tree.tokens.len - 2);

//     try testing.expect(doc.value != null);
//     try testing.expectEqual(doc.value.?.tag, .map);

//     const map = doc.value.?.cast(Node.Map).?;
//     try testing.expectEqual(@intFromEnum(map.base.start), 0);
//     try testing.expectEqual(@intFromEnum(map.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(map.values.items.len, 1);

//     const entry = map.values.items[0];
//     const key = tree.getToken(entry.key);
//     try testing.expectEqual(key.id, .literal);
//     try testing.expectEqualStrings("key", tree.source[key.loc.start..key.loc.end]);

//     const list = entry.value.?.cast(Node.List).?;
//     try testing.expectEqual(@intFromEnum(list.base.start), 4);
//     try testing.expectEqual(@intFromEnum(list.base.end), tree.tokens.len - 2);
//     try testing.expectEqual(list.values.items.len, 3);

//     {
//         try testing.expectEqual(list.values.items[0].tag, .value);
//         const value = list.values.items[0].cast(Node.Value).?;
//         const leaf = tree.getToken(value.base.start);
//         try testing.expectEqualStrings("name", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         try testing.expectEqual(list.values.items[1].tag, .value);
//         const value = list.values.items[1].cast(Node.Value).?;
//         const leaf = tree.getToken(value.base.start);
//         try testing.expectEqualStrings("hr", tree.source[leaf.loc.start..leaf.loc.end]);
//     }

//     {
//         try testing.expectEqual(list.values.items[2].tag, .value);
//         const value = list.values.items[2].cast(Node.Value).?;
//         const leaf = tree.getToken(value.base.start);
//         try testing.expectEqualStrings("avg", tree.source[leaf.loc.start..leaf.loc.end]);
//     }
// }

// fn parseSuccess(comptime source: []const u8) !void {
//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try tree.parse(source);
// }

// fn parseError(comptime source: []const u8, err: parse.ParseError) !void {
//     var tree = Tree.init(testing.allocator);
//     defer tree.deinit();
//     try testing.expectError(err, tree.parse(source));
// }

// test "empty doc with spaces and comments" {
//     try parseSuccess(
//         \\
//         \\
//         \\   # this is a comment in a weird place
//         \\# and this one is too
//     );
// }

// test "comment between --- and ! in document start" {
//     try parseError(
//         \\--- # what is it?
//         \\!
//     , error.UnexpectedToken);
// }

// test "correct doc start with tag" {
//     try parseSuccess(
//         \\--- !some-tag
//         \\
//     );
// }

// test "doc close without explicit doc open" {
//     try parseError(
//         \\
//         \\
//         \\# something cool
//         \\...
//     , error.UnexpectedToken);
// }

// test "doc open and close are ok" {
//     try parseSuccess(
//         \\---
//         \\# first doc
//         \\
//         \\
//         \\---
//         \\# second doc
//         \\
//         \\
//         \\...
//     );
// }

// test "doc with a single string is ok" {
//     try parseSuccess(
//         \\a string of some sort
//         \\
//     );
// }

// test "explicit doc with a single string is ok" {
//     try parseSuccess(
//         \\--- !anchor
//         \\# nothing to see here except one string
//         \\  # not a lot to go on with
//         \\a single string
//         \\...
//     );
// }

// test "doc with two string is bad" {
//     try parseError(
//         \\first
//         \\second
//         \\# this should fail already
//     , error.UnexpectedToken);
// }

// test "single quote string can have new lines" {
//     try parseSuccess(
//         \\'what is this
//         \\ thing?'
//     );
// }

// test "single quote string on one line is fine" {
//     try parseSuccess(
//         \\'here''s an apostrophe'
//     );
// }

// test "double quote string can have new lines" {
//     try parseSuccess(
//         \\"what is this
//         \\ thing?"
//     );
// }

// test "double quote string on one line is fine" {
//     try parseSuccess(
//         \\"a newline\nand a\ttab"
//     );
// }

// test "map with key and value literals" {
//     try parseSuccess(
//         \\key1: val1
//         \\key2 : val2
//     );
// }

// test "map of maps" {
//     try parseSuccess(
//         \\
//         \\# the first key
//         \\key1:
//         \\  # the first subkey
//         \\  key1_1: 0
//         \\  key1_2: 1
//         \\# the second key
//         \\key2:
//         \\  key2_1: -1
//         \\  key2_2: -2
//         \\# the end of map
//     );
// }

// test "map value indicator needs to be on the same line" {
//     try parseError(
//         \\a
//         \\  : b
//     , error.UnexpectedToken);
// }

// test "value needs to be indented" {
//     try parseError(
//         \\a:
//         \\b
//     , error.MalformedYaml);
// }

// test "comment between a key and a value is fine" {
//     try parseSuccess(
//         \\a:
//         \\  # this is a value
//         \\  b
//     );
// }

// test "simple list" {
//     try parseSuccess(
//         \\# first el
//         \\- a
//         \\# second el
//         \\-  b
//         \\# third el
//         \\-   c
//     );
// }

// test "list indentation matters" {
//     try parseError(
//         \\  - a
//         \\- b
//     , error.UnexpectedToken);

//     try parseSuccess(
//         \\- a
//         \\  - b
//     );
// }

// test "unindented list is fine too" {
//     try parseSuccess(
//         \\a:
//         \\- 0
//         \\- 1
//     );
// }

// test "empty values in a map" {
//     try parseSuccess(
//         \\a:
//         \\b:
//         \\- 0
//     );
// }

// test "weirdly nested map of maps of lists" {
//     try parseSuccess(
//         \\a:
//         \\ b:
//         \\  - 0
//         \\  - 1
//     );
// }

// test "square brackets denote a list" {
//     try parseSuccess(
//         \\[ a,
//         \\  b, c ]
//     );
// }

// test "empty list" {
//     try parseSuccess(
//         \\[ ]
//     );
// }

// test "empty map" {
//     try parseSuccess(
//         \\a:
//         \\  b: {}
//         \\  c: { }
//     );
// }

// test "comment within a bracketed list is an error" {
//     try parseError(
//         \\[ # something
//         \\]
//     , error.MalformedYaml);
// }

// test "mixed ints with floats in a list" {
//     try parseSuccess(
//         \\[0, 1.0]
//     );
// }
