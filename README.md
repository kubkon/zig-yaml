# zig-yaml

YAML parser for Zig

## What is it?

This lib is meant to serve as a basic (or maybe not?) YAML parser for Zig. It will strive to be YAML 1.2 compatible
but one step at a time.

This is very much a work-in-progress, so expect things to break on a regular basis. Oh, I'd love to get the
community involved in helping out with this btw! Feel free to fork and submit patches/enhancements, and of course
issues.

## Basic usage

The parser currently understands a few YAML primitives such as:
* explicit documents (`---`, `...`)
* mappings (`:`)
* sequences (`-`)

In fact, if you head over to `examples/` dir, you will find YAML examples that have been tested against this
parser. This reminds me to add a TODO to convert `examples/` into end-to-end tests!

If you want to use the parser as a library, add it as a package the usual way, and then:

1. For untyped, raw representation of YAML, use `Yaml.load`:

```zig
const std = @import("std");
const yaml = @import("yaml");

const source =
    \\a: 0
;

pub fn main() !void {
    var decoder = yaml.Yaml.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.load(source);
    
    try std.testing.expectEqual(decoder.docs.items.len, 1);

    const map = decoder.docs.items[0].map;
    try std.testing.expect(map.contains("a"));
    try std.testing.expect(std.mem.eql(u8, map.get("a").?.string, "0"));
}
```

2. For typed representation of YAML, use `Yaml.parse`:

```zig
const std = @import("std");
const yaml = @import("yaml");

const source =
    \\a: 0
;

const Simple = struct {
    a: usize,
};

pub fn main() !void {
    var decoder = yaml.Yaml.init(std.testing.allocator);
    defer decoder.deinit();

    const simple = try yaml.parse(Simple, source);
    try std.testing.expectEqual(simple.a, 0);
}
```
