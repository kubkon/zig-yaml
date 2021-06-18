# zig-yaml

YAML parser for Zig

## What is it?

This lib is meant to serve as a basic (or maybe not?) YAML parser for Zig. It will strive to be YAML 1.2 compatible
but one step at a time.

This is very much a work-in-progress, so expect things to break on a regular basis. Oh, I'd love to get the
community involved in helping out with this btw! Feel free to fork and submit patches, enhancements, and of course
issues.

## Basic usage

The parser currently understands a few YAML primitives such as:
* explicit documents (`---`, `...`)
* mappings (`:`)
* sequences (`-`, `[`, `]`)

In fact, if you head over to `examples/` dir, you will find YAML examples that have been tested against this
parser. You can also have a look at end-to-end test inputs in `test/` directory.

If you want to use the parser as a library, add it as a package the usual way, and then:

```zig
const std = @import("std");
const yaml = @import("yaml");

const source =
    \\names: [ John Doe, MacIntosh, Jane Austin ]
    \\numbers:
    \\  - 10
    \\  - -8
    \\  - 6
    \\nested:
    \\  some: one
    \\  wick: john doe
    \\finally: [ 8.17,
    \\           19.78      , 17 ,
    \\           21 ]
;
```

1. For untyped, raw representation of YAML, use `Yaml.load`:

```zig
var untyped = try yaml.Yaml.load(std.testing.allocator, source);
defer untyped.deinit();

try std.testing.expectEqual(untyped.docs.items.len, 1);

const map = untyped.docs.items[0].map;
try std.testing.expect(map.contains("names"));
try std.testing.expectEqual(map.get("names").?.list.len, 3);
```

2. For typed representation of YAML, use `Yaml.parse`:

```zig
const Simple = struct {
    names: []const []const u8,
    numbers: []const i16,
    nested: struct {
        some: []const u8,
        wick: []const u8,
    },
    finally: [4]f16,
};

const simple = try untyped.parse(Simple);
try std.testing.expectEqual(simple.names.len, 3);
```

3. To convert `Yaml` structure back into text representation, use `Yaml.stringify`:

```zig
try untyped.stringify(std.io.getStdOut().writer());
```

which should write the following output to standard output when run:

```sh
names: [ John Doe, MacIntosh, Jane Austin  ]
numbers: [ 10, -8, 6  ]
nested:
    some: one
    wick: john doe
finally: [ 8.17, 19.78, 17, 21  ]
```
