const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Yaml = @import("../yaml.zig").Yaml;

test "simple list" {
    const source =
        \\- a
        \\- b
        \\- c
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const list = yaml.docs.items[0].list;
    try testing.expectEqual(list.len, 3);

    try testing.expect(mem.eql(u8, list[0].string, "a"));
    try testing.expect(mem.eql(u8, list[1].string, "b"));
    try testing.expect(mem.eql(u8, list[2].string, "c"));
}

test "simple list typed as array of strings" {
    const source =
        \\- a
        \\- b
        \\- c
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3][]const u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expect(mem.eql(u8, arr[0], "a"));
    try testing.expect(mem.eql(u8, arr[1], "b"));
    try testing.expect(mem.eql(u8, arr[2], "c"));
}

test "simple list typed as array of ints" {
    const source =
        \\- 0
        \\- 1
        \\- 2
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3]u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expectEqual(arr[0], 0);
    try testing.expectEqual(arr[1], 1);
    try testing.expectEqual(arr[2], 2);
}

test "list of mixed sign integer" {
    const source =
        \\- 0
        \\- -1
        \\- 2
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const arr = try yaml.parse([3]i8);
    try testing.expectEqual(arr.len, 3);
    try testing.expectEqual(arr[0], 0);
    try testing.expectEqual(arr[1], -1);
    try testing.expectEqual(arr[2], 2);
}

test "simple map untyped" {
    const source =
        \\a: 0
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const map = yaml.docs.items[0].map;
    try testing.expect(map.contains("a"));
    try testing.expectEqual(map.get("a").?.int, 0);
}

test "simple map untyped with a list of maps" {
    const source =
        \\a: 0
        \\b:
        \\  - foo: 1
        \\    bar: 2
        \\  - foo: 3
        \\    bar: 4
        \\c: 1
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const map = yaml.docs.items[0].map;
    try testing.expect(map.contains("a"));
    try testing.expect(map.contains("b"));
    try testing.expect(map.contains("c"));
    try testing.expectEqual(map.get("a").?.int, 0);
    try testing.expectEqual(map.get("c").?.int, 1);
    try testing.expectEqual(map.get("b").?.list[0].map.get("foo").?.int, 1);
    try testing.expectEqual(map.get("b").?.list[0].map.get("bar").?.int, 2);
    try testing.expectEqual(map.get("b").?.list[1].map.get("foo").?.int, 3);
    try testing.expectEqual(map.get("b").?.list[1].map.get("bar").?.int, 4);
}

test "simple map untyped with a list of maps. no indent" {
    const source =
        \\b:
        \\- foo: 1
        \\c: 1
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const map = yaml.docs.items[0].map;
    try testing.expect(map.contains("b"));
    try testing.expect(map.contains("c"));
    try testing.expectEqual(map.get("c").?.int, 1);
    try testing.expectEqual(map.get("b").?.list[0].map.get("foo").?.int, 1);
}

test "simple map untyped with a list of maps. no indent 2" {
    const source =
        \\a: 0
        \\b:
        \\- foo: 1
        \\  bar: 2
        \\- foo: 3
        \\  bar: 4
        \\c: 1
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectEqual(yaml.docs.items.len, 1);

    const map = yaml.docs.items[0].map;
    try testing.expect(map.contains("a"));
    try testing.expect(map.contains("b"));
    try testing.expect(map.contains("c"));
    try testing.expectEqual(map.get("a").?.int, 0);
    try testing.expectEqual(map.get("c").?.int, 1);
    try testing.expectEqual(map.get("b").?.list[0].map.get("foo").?.int, 1);
    try testing.expectEqual(map.get("b").?.list[0].map.get("bar").?.int, 2);
    try testing.expectEqual(map.get("b").?.list[1].map.get("foo").?.int, 3);
    try testing.expectEqual(map.get("b").?.list[1].map.get("bar").?.int, 4);
}

test "simple map typed" {
    const source =
        \\a: 0
        \\b: hello there
        \\c: 'wait, what?'
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const simple = try yaml.parse(struct { a: usize, b: []const u8, c: []const u8 });
    try testing.expectEqual(simple.a, 0);
    try testing.expect(mem.eql(u8, simple.b, "hello there"));
    try testing.expect(mem.eql(u8, simple.c, "wait, what?"));
}

test "typed nested structs" {
    const source =
        \\a:
        \\  b: hello there
        \\  c: 'wait, what?'
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const simple = try yaml.parse(struct {
        a: struct {
            b: []const u8,
            c: []const u8,
        },
    });
    try testing.expect(mem.eql(u8, simple.a.b, "hello there"));
    try testing.expect(mem.eql(u8, simple.a.c, "wait, what?"));
}

test "single quoted string" {
    const source =
        \\- 'hello'
        \\- 'here''s an escaped quote'
        \\- 'newlines and tabs\nare not\tsupported'
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const arr = try yaml.parse([3][]const u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expect(mem.eql(u8, arr[0], "hello"));
    try testing.expect(mem.eql(u8, arr[1], "here's an escaped quote"));
    try testing.expect(mem.eql(u8, arr[2], "newlines and tabs\\nare not\\tsupported"));
}

test "double quoted string" {
    const source =
        \\- "hello"
        \\- "\"here\" are some escaped quotes"
        \\- "newlines and tabs\nare\tsupported"
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const arr = try yaml.parse([3][]const u8);
    try testing.expectEqual(arr.len, 3);
    try testing.expect(mem.eql(u8, arr[0], "hello"));
    try testing.expect(mem.eql(u8, arr[1],
        \\"here" are some escaped quotes
    ));
    try testing.expect(mem.eql(u8, arr[2],
        \\newlines and tabs
        \\are	supported
    ));
}

test "multidoc typed as a slice of structs" {
    const source =
        \\---
        \\a: 0
        \\---
        \\a: 1
        \\...
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    {
        const result = try yaml.parse([2]struct { a: usize });
        try testing.expectEqual(result.len, 2);
        try testing.expectEqual(result[0].a, 0);
        try testing.expectEqual(result[1].a, 1);
    }

    {
        const result = try yaml.parse([]struct { a: usize });
        try testing.expectEqual(result.len, 2);
        try testing.expectEqual(result[0].a, 0);
        try testing.expectEqual(result[1].a, 1);
    }
}

test "multidoc typed as a struct is an error" {
    const source =
        \\---
        \\a: 0
        \\---
        \\b: 1
        \\...
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectError(Yaml.Error.TypeMismatch, yaml.parse(struct { a: usize }));
    try testing.expectError(Yaml.Error.TypeMismatch, yaml.parse(struct { b: usize }));
    try testing.expectError(Yaml.Error.TypeMismatch, yaml.parse(struct { a: usize, b: usize }));
}

test "multidoc typed as a slice of structs with optionals" {
    const source =
        \\---
        \\a: 0
        \\c: 1.0
        \\---
        \\a: 1
        \\b: different field
        \\...
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const result = try yaml.parse([]struct { a: usize, b: ?[]const u8, c: ?f16 });
    try testing.expectEqual(result.len, 2);

    try testing.expectEqual(result[0].a, 0);
    try testing.expect(result[0].b == null);
    try testing.expect(result[0].c != null);
    try testing.expectEqual(result[0].c.?, 1.0);

    try testing.expectEqual(result[1].a, 1);
    try testing.expect(result[1].b != null);
    try testing.expect(mem.eql(u8, result[1].b.?, "different field"));
    try testing.expect(result[1].c == null);
}

test "empty yaml can be represented as void" {
    const source = "";
    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();
    const result = try yaml.parse(void);
    try testing.expect(@TypeOf(result) == void);
}

test "nonempty yaml cannot be represented as void" {
    const source =
        \\a: b
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectError(Yaml.Error.TypeMismatch, yaml.parse(void));
}

test "typed array size mismatch" {
    const source =
        \\- 0
        \\- 0
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    try testing.expectError(Yaml.Error.ArraySizeMismatch, yaml.parse([1]usize));
    try testing.expectError(Yaml.Error.ArraySizeMismatch, yaml.parse([5]usize));
}

test "comments" {
    const source =
        \\
        \\key: # this is the key
        \\# first value
        \\
        \\- val1
        \\
        \\# second value
        \\- val2
    ;

    var yaml = try Yaml.load(testing.allocator, source);
    defer yaml.deinit();

    const simple = try yaml.parse(struct {
        key: []const []const u8,
    });
    try testing.expect(simple.key.len == 2);
    try testing.expect(mem.eql(u8, simple.key[0], "val1"));
    try testing.expect(mem.eql(u8, simple.key[1], "val2"));
}
