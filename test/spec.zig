const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const Allocator = mem.Allocator;
const Step = std.Build.Step;
const SpecTest = @This();

pub const base_id: Step.Id = .custom;

step: Step,
output_file: std.Build.GeneratedFile,

const test_filename = "yaml_test_suite.zig";

const preamble =
    \\// This file is generated from the YAML 1.2 test database.
    \\
    \\const std = @import("std");
    \\const testing = std.testing;
    \\
    \\const Yaml = @import("yaml").Yaml;
    \\
    \\const alloc = testing.allocator;
    \\
    \\fn loadFromFile(file_path: []const u8) !Yaml {
    \\    const file = try std.fs.openFileAbsolute(file_path, .{});
    \\    defer file.close();
    \\
    \\    const source = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
    \\    defer alloc.free(source);
    \\
    \\    var yaml: Yaml = .{ .source = source };
    \\    errdefer yaml.deinit(alloc);
    \\    try yaml.load(alloc);
    \\    return yaml;
    \\}
    \\
    \\fn loadFileString(file_path: []const u8) ![]u8 {
    \\    const file = try std.fs.openFileAbsolute(file_path, .{});
    \\    defer file.close();
    \\
    \\    const source = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
    \\    return source;
    \\}
    \\
;

pub fn create(owner: *std.Build) *SpecTest {
    const spec_test = owner.allocator.create(SpecTest) catch @panic("OOM");

    spec_test.* = .{
        .step = Step.init(.{ .id = base_id, .name = "yaml-test-generate", .owner = owner, .makeFn = make }),
        .output_file = std.Build.GeneratedFile{ .step = &spec_test.step },
    };
    return spec_test;
}

pub fn path(spec_test: *SpecTest) std.Build.LazyPath {
    return std.Build.LazyPath{ .generated = .{ .file = &spec_test.output_file } };
}

const Testcase = struct {
    name: []const u8,
    path: []const u8,
    result: union(enum) {
        expected_output_path: []const u8,
        error_expected,
        none,
        skip,
    },
    tags: std.BufSet,
};

fn make(step: *Step, make_options: Step.MakeOptions) !void {
    _ = make_options;

    const spec_test: *SpecTest = @fieldParentPtr("step", step);
    const b = step.owner;

    const cwd = std.fs.cwd();
    cwd.access("test/yaml-test-suite/tags", .{}) catch {
        return spec_test.step.fail("Testfiles not found, make sure you have loaded the submodule.", .{});
    };
    if (b.graph.host.result.os.tag == .windows) {
        return spec_test.step.fail("Windows does not support symlinks in git properly, can't run testsuite.", .{});
    }

    var arena_allocator = std.heap.ArenaAllocator.init(b.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var testcases = std.StringArrayHashMap(Testcase).init(arena);

    const root_data_path = try fs.path.join(arena, &[_][]const u8{
        b.build_root.path.?,
        "test/yaml-test-suite",
    });

    const root_data_dir = try std.fs.openDirAbsolute(root_data_path, .{});

    var itdir = try root_data_dir.openDir("tags", .{
        .iterate = true,
        .access_sub_paths = true,
    });

    var walker = try itdir.walk(arena);
    defer walker.deinit();

    loop: {
        while (walker.next()) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (entry.kind != .sym_link) continue;
                collectTest(arena, entry, &testcases) catch |err| switch (err) {
                    error.OutOfMemory => @panic("OOM"),
                    else => |e| return e,
                };
            } else {
                break :loop;
            }
        } else |err| {
            std.debug.print("err: {}", .{err});
            break :loop;
        }
    }

    var output = std.ArrayList(u8).init(arena);
    const writer = output.writer();
    try writer.writeAll(preamble);

    while (testcases.pop()) |kv| {
        emitTest(arena, &output, kv.value) catch |err| switch (err) {
            error.OutOfMemory => @panic("OOM"),
            else => |e| return e,
        };
    }

    var man = b.graph.cache.obtain();
    defer man.deinit();

    man.hash.addBytes(output.items);

    if (try step.cacheHit(&man)) {
        const digest = man.final();
        spec_test.output_file.path = try b.cache_root.join(b.allocator, &.{
            &digest, test_filename,
        });
        return;
    }
    const digest = man.final();

    const sub_path = b.pathJoin(&.{ &digest, test_filename });
    const sub_path_dirname = fs.path.dirname(sub_path).?;

    b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
        return step.fail("unable to make path '{?s}{s}': {any}", .{ b.cache_root.path, sub_path_dirname, err });
    };

    b.cache_root.handle.writeFile(.{ .sub_path = sub_path, .data = output.items }) catch |err| {
        return step.fail("unable to write file: {}", .{err});
    };
    spec_test.output_file.path = try b.cache_root.join(b.allocator, &.{sub_path});
    try man.writeManifest();
}

fn collectTest(arena: Allocator, entry: fs.Dir.Walker.Entry, testcases: *std.StringArrayHashMap(Testcase)) !void {
    var path_components_it = try std.fs.path.componentIterator(entry.path);
    const first_path = path_components_it.first().?;

    var path_components = std.ArrayList([]const u8).init(arena);
    while (path_components_it.next()) |component| {
        try path_components.append(component.name);
    }

    const remaining_path = try fs.path.join(arena, path_components.items);
    const result = try testcases.getOrPut(remaining_path);

    if (!result.found_existing) {
        result.key_ptr.* = remaining_path;

        const in_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "in.yaml",
        });
        const real_in_path = try entry.dir.realpathAlloc(arena, in_path);

        const name_file_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "===",
        });
        const name_file = try entry.dir.openFile(name_file_path, .{});
        defer name_file.close();
        const name = try name_file.readToEndAlloc(arena, std.math.maxInt(u32));

        var tag_set = std.BufSet.init(arena);
        try tag_set.insert(first_path.name);

        const full_name = try std.fmt.allocPrint(arena, "{s} - {s}", .{
            remaining_path,
            name[0 .. name.len - 1],
        });

        result.value_ptr.* = .{
            .name = full_name,
            .path = real_in_path,
            .result = .{ .none = {} },
            .tags = tag_set,
        };

        if (skipTest(full_name)) {
            result.value_ptr.result = .skip;
            return;
        }

        const out_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "out.yaml",
        });
        const err_path = try fs.path.join(arena, &[_][]const u8{
            entry.basename,
            "error",
        });

        if (canAccess(entry.dir, out_path)) {
            const real_out_path = try entry.dir.realpathAlloc(arena, out_path);
            result.value_ptr.result = .{ .expected_output_path = real_out_path };
        } else if (canAccess(entry.dir, err_path)) {
            result.value_ptr.result = .{ .error_expected = {} };
        }
    } else {
        try result.value_ptr.tags.insert(first_path.name);
    }
}

fn skipTest(name: []const u8) bool {
    for (skipped_tests) |skipped_name| {
        if (mem.eql(u8, name, skipped_name)) return true;
    }
    return false;
}

const skipped_tests = &[_][]const u8{
    "JR7V - Question marks in scalars",
    "UDM2 - Plain URL in flow mapping",
    "8MK2 - Explicit Non-Specific Tag",
    "6XDY - Two document start markers",
    "652Z - Question mark at start of flow key",
    "PUW8 - Document start on last line",
    "FBC9 - Allowed characters in plain scalars",
    "5TRB - Invalid document-start marker in doublequoted tring",
    "9MQT/01 - Scalar doc with '...' in content",
    "9MQT/00 - Scalar doc with '...' in content",
    "CPZ3 - Doublequoted scalar starting with a tab",
    "8XYN - Anchor with unicode character",
    "Y2GN - Anchor with colon in the middle",
    "KSS4 - Scalars on --- line",
    "FTA2 - Single block sequence with anchor and explicit document start",
    "3R3P - Single block sequence with anchor",
    "F2C7 - Anchors and Tags",
    "TS54 - Folded Block Scalar",
    "MZX3 - Non-Specific Tags on Scalars",
    "AB8U - Sequence entry that looks like two with wrong indentation",
    "9MAG - Flow sequence with invalid comma at the beginning",
    "YJV2 - Dash in flow sequence",
    "FUP4 - Flow Sequence in Flow Sequence",
    "33X3 - Three explicit integers in a block sequence",
    "2AUY - Tags in Block Sequence",
    "SM9W/00 - Single character streams",
    "G5U8 - Plain dashes in flow sequence",
    "DHP8 - Flow Sequence",
    "3MYT - Plain Scalar looking like key, comment, anchor and tag",
    "A984 - Multiline Scalar in Mapping",
    "S7BG - Colon followed by comma",
    "HM87/00 - Scalars in flow start with syntax char",
    "HM87/01 - Scalars in flow start with syntax char",
    "4V8U - Plain scalar with backslashes",
    "H3Z8 - Literal unicode",
    "82AN - Three dashes and content without space",
    "BS4K - Comment between plain scalar lines",
    "FH7J - Tags on Empty Scalars",
    "CQ3W - Double quoted string without closing quote",
    "Y79Y/001 - Tabs in various contexts",
    "Y79Y/006 - Tabs in various contexts",
    "Y79Y/010 - Tabs in various contexts",
    "Y79Y/003 - Tabs in various contexts",
    "Y79Y/004 - Tabs in various contexts",
    "Y79Y/005 - Tabs in various contexts",
    "Y79Y/002 - Tabs in various contexts",
    "9YRD - Multiline Scalar at Top Level",
    "CFD4 - Empty implicit key in single pair flow sequences",
    "3UYS - Escaped slash in double quotes",
    "Y79Y/008 - Tabs in various contexts",
    "UV7Q - Legal tab after indentation",
    "SKE5 - Anchor before zero indented sequence",
    "EW3V - Wrong indendation in mapping",
    "DK95/03 - Tabs that look like indentation",
    "DK95/04 - Tabs that look like indentation",
    "DK95/05 - Tabs that look like indentation",
    "DK95/07 - Tabs that look like indentation",
    "DK95/00 - Tabs that look like indentation",
    "DK95/01 - Tabs that look like indentation",
    "DK95/06 - Tabs that look like indentation",
    "ZVH3 - Wrong indented sequence item",
    "96NN/00 - Leading tab content in literals",
    "96NN/01 - Leading tab content in literals",
    "F6MC - More indented lines at the beginning of folded block scalars",
    "Y79Y/009 - Tabs in various contexts",
    "Y79Y/000 - Tabs in various contexts",
    "Y79Y/007 - Tabs in various contexts",
    "KH5V/01 - Inline tabs in double quoted",
    "KH5V/02 - Inline tabs in double quoted",
    "Q5MG - Tab at beginning of line followed by a flow mapping",
    "4RWC - Trailing spaces after flow collection",
    "LP6E - Whitespace After Scalars in Flow",
    "NHX8 - Empty Lines at End of Document",
    "NB6Z - Multiline plain value with tabs on empty lines",
    "DE56/01 - Trailing tabs in double quoted",
    "DE56/00 - Trailing tabs in double quoted",
    "DE56/02 - Trailing tabs in double quoted",
    "DE56/05 - Trailing tabs in double quoted",
    "DE56/04 - Trailing tabs in double quoted",
    "DE56/03 - Trailing tabs in double quoted",
    "L24T/01 - Trailing line of spaces",
    "L24T/00 - Trailing line of spaces",
    "3RLN/01 - Leading tabs in double quoted",
    "3RLN/04 - Leading tabs in double quoted",
    "9MMA - Directive by itself with no document",
    "MUS6/06 - Directive variants",
    "MUS6/02 - Directive variants",
    "MUS6/05 - Directive variants",
    "MUS6/04 - Directive variants",
    "MUS6/03 - Directive variants",
    "XLQ9 - Multiline scalar that looks like a YAML directive",
    "M2N8/01 - Question mark edge cases",
    "M2N8/00 - Question mark edge cases",
    "UKK6/01 - Syntax character edge cases",
    "UKK6/00 - Syntax character edge cases",
    "UKK6/02 - Syntax character edge cases",
    "6H3V - Backslashes in singlequotes",
    "U3C3 - Spec Example 6.16. “TAG” directive",
    "DBG4 - Spec Example 7.10. Plain Characters",
    "MJS9 - Spec Example 6.7. Block Folding",
    "96L6 - Spec Example 2.14. In the folded scalars, newlines become spaces",
    "4CQQ - Spec Example 2.18. Multi-line Flow Scalars",
    "6CK3 - Spec Example 6.26. Tag Shorthands",
    "BEC7 - Spec Example 6.14. “YAML” directive",
    "WZ62 - Spec Example 7.2. Empty Content",
    "5TYM - Spec Example 6.21. Local Tag Prefix",
    "27NA - Spec Example 5.9. Directive Indicator",
    "JHB9 - Spec Example 2.7. Two Documents in a Stream",
    "LQZ7 - Spec Example 7.4. Double Quoted Implicit Keys",
    "S4JQ - Spec Example 6.28. Non-Specific Tags",
    "G992 - Spec Example 8.9. Folded Scalar",
    "YD5X - Spec Example 2.5. Sequence of Sequences",
    "8UDB - Spec Example 7.14. Flow Sequence Entries",
    "6ZKB - Spec Example 9.6. Stream",
    "G4RS - Spec Example 2.17. Quoted Scalars",
    "6LVF - Spec Example 6.13. Reserved Directives",
    "5KJE - Spec Example 7.13. Flow Sequence",
    "6VJK - Spec Example 2.15. Folded newlines are preserved for \"more indented\" and blank lines",
    "K527 - Spec Example 6.6. Line Folding",
    "SU5Z - Comment without whitespace after doublequoted scalar",
    "L383 - Two scalar docs with trailing comments",
    "DC7X - Various trailing tabs",
    "U3XV - Node and Mapping Key Anchors",
    "Q9WF - Spec Example 6.12. Separation Spaces",
    "7T8X - Spec Example 8.10. Folded Lines - 8.13. Final Empty Lines",
    "CML9 - Missing comma in flow",
    "P94K - Spec Example 6.11. Multi-Line Comments",
    "7TMG - Comment in flow sequence before comma",
    "DK3J - Zero indented block scalar with line that looks like a comment",
    "SYW4 - Spec Example 2.2. Mapping Scalars to Scalars",
    "735Y - Spec Example 8.20. Block Node Types",
    "B3HG - Spec Example 8.9. Folded Scalar [1.3]",
    "6WLZ - Spec Example 6.18. Primary Tag Handle [1.3]",
    "EX5H - Multiline Scalar at Top Level [1.3]",
    "4Q9F - Folded Block Scalar [1.3]",
    "Q8AD - Spec Example 7.5. Double Quoted Line Breaks [1.3]",
    "6WPF - Spec Example 6.8. Flow Folding [1.3]",
    "SSW6 - Spec Example 7.7. Single Quoted Characters [1.3]",
    "9DXL - Spec Example 9.6. Stream [1.3]",
    "EXG3 - Three dashes and content without space [1.3]",
    "T4YY - Spec Example 7.9. Single Quoted Lines [1.3]",
    "9TFX - Spec Example 7.6. Double Quoted Lines [1.3]",
    "93WF - Spec Example 6.6. Line Folding [1.3]",
    "52DL - Explicit Non-Specific Tag [1.3]",
    "2LFX - Spec Example 6.13. Reserved Directives [1.3]",
    "PW8X - Anchors on Empty Scalars",
    "XW4D - Various Trailing Comments",
    "NP9H - Spec Example 7.5. Double Quoted Line Breaks",
    "HS5T - Spec Example 7.12. Plain Lines",
    "J3BT - Spec Example 5.12. Tabs and Spaces",
    "PRH3 - Spec Example 7.9. Single Quoted Lines",
    "7A4E - Spec Example 7.6. Double Quoted Lines",
    "TL85 - Spec Example 6.8. Flow Folding",
    "8G76 - Spec Example 6.10. Comment Lines",
    "98YD - Spec Example 5.5. Comment Indicator",
    "M29M - Literal Block Scalar",
    "P2AD - Spec Example 8.1. Block Scalar Header",
    "T26H - Spec Example 8.8. Literal Content [1.3]",
    "W42U - Spec Example 8.15. Block Sequence Entry Types",
    "XV9V - Spec Example 6.5. Empty Lines [1.3]",
    "5GBF - Spec Example 6.5. Empty Lines",
    "JEF9/01 - Trailing whitespace in streams",
    "JEF9/00 - Trailing whitespace in streams",
    "JEF9/02 - Trailing whitespace in streams",
    "A6F9 - Spec Example 8.4. Chomping Final Line Break",
    "4ZYM - Spec Example 6.4. Line Prefixes",
    "6FWR - Block Scalar Keep",
    "2G84/01 - Literal modifers",
    "2G84/00 - Literal modifers",
    "DWX9 - Spec Example 8.8. Literal Content",
    "F8F9 - Spec Example 8.5. Chomping Trailing Lines",
    "MYW6 - Block Scalar Strip",
    "H2RW - Blank lines",
    "6JQW - Spec Example 2.13. In literals, newlines are preserved",
    "K858 - Spec Example 8.6. Empty Scalar Chomping",
    "5BVJ - Spec Example 5.7. Block Scalar Indicators",
    "T5N4 - Spec Example 8.7. Literal Scalar [1.3]",
    "M9B4 - Spec Example 8.7. Literal Scalar",
    "753E - Block Scalar Strip [1.3]",
    "HMK4 - Spec Example 2.16. Indentation determines scope",
    "Z9M4 - Spec Example 6.22. Global Tag Prefix",
    "9WXW - Spec Example 6.18. Primary Tag Handle",
    "565N - Construct Binary",
    "P76L - Spec Example 6.19. Secondary Tag Handle",
    "CC74 - Spec Example 6.20. Tag Handles",
    "CUP7 - Spec Example 5.6. Node Property Indicators",
    "6M2F - Aliases in Explicit Block Mapping",
    "HMQ5 - Spec Example 6.23. Node Properties",
    "JS2J - Spec Example 6.29. Node Anchors",
    "LE5A - Spec Example 7.24. Flow Nodes",
    "C4HZ - Spec Example 2.24. Global Tags",
    "X38W - Aliases in Flow Objects",
    "W5VH - Allowed characters in alias",
    "V55R - Aliases in Block Sequence",
    "6KGN - Anchor for empty node",
    "4QFQ - Spec Example 8.2. Block Indentation Indicator [1.3]",
    "R4YG - Spec Example 8.2. Block Indentation Indicator",
    "6BCT - Spec Example 6.3. Separation Spaces",
    "UT92 - Spec Example 9.4. Explicit Documents",
    "7Z25 - Bare document after document end marker",
    "EB22 - Missing document-end marker before directive",
    "3HFZ - Invalid content after document end marker",
    "QT73 - Comment and document-end marker",
    "HWV9 - Document-end marker",
    "RXY3 - Invalid document-end marker in single quoted string",
    "RTP8 - Spec Example 9.2. Document Markers",
    "W4TN - Spec Example 9.5. Directives Documents",
    "M7A3 - Spec Example 9.3. Bare Documents",
    "RZT7 - Spec Example 2.28. Log File",
    "5T43 - Colon at the beginning of adjacent flow scalar",
    "7BUB - Spec Example 2.10. Node for “Sammy Sosa” appears twice in this document",
    "5C5M - Spec Example 7.15. Flow Mappings",
    "ZCZ6 - Invalid mapping in plain single line value",
    "5MUD - Colon and adjacent value on next line",
    "54T7 - Flow Mapping",
    "6SLA - Allowed characters in quoted mapping key",
    "X8DW - Explicit key and value seperated by comment",
    "S3PD - Spec Example 8.18. Implicit Block Mapping Entries",
    "4ABK - Flow Mapping Separate Values",
    "8KB6 - Multiline plain flow mapping key without value",
    "7W2P - Block Mapping with Missing Values",
    "ZWK4 - Key with anchor after missing explicit mapping value",
    "2SXE - Anchors With Colon in Name",
    "4FJ6 - Nested implicit complex keys",
    "ZF4X - Spec Example 2.6. Mapping of Mappings",
    "ZH7C - Anchors in Mapping",
    "TE2A - Spec Example 8.16. Block Mappings",
    "SM9W/01 - Single character streams",
    "KK5P - Various combinations of explicit block mappings",
    "5U3A - Sequence on same Line as Mapping Key",
    "8QBE - Block Sequence in Block Mapping",
    "26DV - Whitespace around colon in mappings",
    "CT4Q - Spec Example 7.20. Single Pair Explicit Entry",
    "NKF9 - Empty keys in block and flow mapping",
    "R52L - Nested flow mapping sequence and mappings",
    "87E4 - Spec Example 7.8. Single Quoted Implicit Keys",
    "UGM3 - Spec Example 2.27. Invoice",
    "NJ66 - Multiline plain flow mapping key",
    "QF4Y - Spec Example 7.19. Single Pair Flow Mappings",
    "E76Z - Aliases in Implicit Block Mapping",
    "DFF7 - Spec Example 7.16. Flow Mapping Entries",
    "6JWB - Tags for Block Objects",
    "2JQS - Block Mapping with Missing Keys",
    "D88J - Flow Sequence in Block Mapping",
    "3GZX - Spec Example 7.1. Alias Nodes",
    "5NYZ - Spec Example 6.9. Separated Comment",
    "8CWC - Plain mapping key ending with colon",
    "5WE3 - Spec Example 8.17. Explicit Block Mapping Entries",
    "4EJS - Invalid tabs as indendation in a mapping",
    "JTV5 - Block Mapping with Multiline Scalars",
    "EHF6 - Tags for Flow Objects",
    "M7NX - Nested flow collections",
    "CN3R - Various location of anchors in flow sequence",
    "K3WX - Colon and adjacent value after comment on next line",
    "C2DT - Spec Example 7.18. Flow Mapping Adjacent Values",
    "36F6 - Multiline plain scalar with empty line",
    "Q88A - Spec Example 7.23. Flow Content",
    "L9U5 - Spec Example 7.11. Plain Implicit Keys",
    "F3CP - Nested flow collections on one line",
    "93JH - Block Mappings in Block Sequence",
    "V9D5 - Spec Example 8.19. Compact Block Mappings",
    "74H7 - Tags in Implicit Mapping",
    "RR7F - Mixed Block Mapping (implicit to explicit)",
    "J9HZ - Spec Example 2.9. Single Document with Two Comments",
    "229Q - Spec Example 2.4. Sequence of Mappings",
    "57H4 - Spec Example 8.22. Block Collection Nodes",
    "9SA2 - Multiline double quoted flow mapping key",
    "MXS3 - Flow Mapping in Block Sequence",
    "L94M - Tags in Explicit Mapping",
    "J7VC - Empty Lines Between Mapping Elements",
    "J7PZ - Spec Example 2.26. Ordered Mappings",
    "9KAX - Various combinations of tags and anchors",
    "7ZZ5 - Empty flow collections",
    "9U5K - Spec Example 2.12. Compact Nested Mapping",
    "6PBE - Zero-indented sequences in explicit mapping keys",
    "ZL4Z - Invalid nested mapping",
    "S4T7 - Document with footer",
    "4MUZ/01 - Flow mapping colon on line after key",
    "4MUZ/00 - Flow mapping colon on line after key",
    "4MUZ/02 - Flow mapping colon on line after key",
    "9KBC - Mapping starting at --- line",
    "9BXH - Multiline doublequoted flow mapping key without value",
    "9MMW - Single Pair Implicit Entries",
    "7BMT - Node and Mapping Key Anchors [1.3]",
    "LX3P - Implicit Flow Mapping Key on one line",
    "PBJ2 - Spec Example 2.3. Mapping Scalars to Sequences",
    "JQ4R - Spec Example 8.14. Block Sequence",
    "2EBW - Allowed characters in keys",
    "SBG9 - Flow Sequence in Flow Mapping",
    "UDR7 - Spec Example 5.4. Flow Collection Indicators",
    "FRK4 - Spec Example 7.3. Completely Empty Flow Nodes",
    "35KP - Tags for Root Objects",
    "58MP - Flow mapping edge cases",
    "S9E8 - Spec Example 5.3. Block Structure Indicators",
    "6BFJ - Mapping, key and flow sequence item anchors",
    "RZP5 - Various Trailing Comments [1.3]",
    "2XXW - Spec Example 2.25. Unordered Sets",
    "7FWL - Spec Example 6.24. Verbatim Tags",
    "M5DY - Spec Example 2.11. Mapping between Sequences",
    "GH63 - Mixed Block Mapping (explicit to implicit)",
    "HU3P - Invalid Mapping in plain scalar",
    "6HB6 - Spec Example 6.1. Indentation Spaces",
    "FP8R - Zero indented block scalar",
    "Z67P - Spec Example 8.21. Block Scalar Nodes [1.3]",
    "A2M4 - Spec Example 6.2. Indentation Indicators",
    "VJP3/01 - Flow collections over many lines",
    "6CA3 - Tab indented top flow",
    "BU8L - Node Anchor and Tag on Seperate Lines",
    "4HVU - Wrong indendation in Sequence",
    "U44R - Bad indentation in mapping (2)",
    "DMG6 - Wrong indendation in Map",
    "ZK9H - Nested top level flow mapping",
    "M6YH - Block sequence indentation",
    "M5C3 - Spec Example 8.21. Block Scalar Nodes",
    "9C9N - Wrong indented flow sequence",
    "N4JP - Bad indentation in mapping",
    "4WA9 - Literal scalars",
    "QB6E - Wrong indented multiline quoted scalar",
    "D83L - Block scalar indicator order",
    "RLU9 - Sequence Indent",
    "UV7Q - Legal tab after indentation",
    "K54U - Tab after document header",
};

const skip_test_template =
    \\ return error.SkipZigTest;
;

const no_output_template =
    \\    var yaml = try loadFromFile("{s}");
    \\    defer yaml.deinit(alloc);
    \\
;

const expect_file_template =
    \\    var yaml = try loadFromFile("{s}");
    \\    defer yaml.deinit(alloc);
    \\
    \\    const expected = try loadFileString("{s}");
    \\    defer alloc.free(expected);
    \\
    \\    var buf = std.ArrayList(u8).init(alloc);
    \\    defer buf.deinit();
    \\    try yaml.stringify(&buf.writer());
    \\    const actual = try buf.toOwnedSlice();
    \\    try testing.expect(std.meta.eql(expected, actual));
    \\
;

const expect_err_template =
    \\    var yaml = loadFromFile("{s}") catch return;
    \\    defer yaml.deinit(alloc);
    \\    return error.UnexpectedSuccess;
    \\
;

fn emitTest(arena: Allocator, output: *std.ArrayList(u8), testcase: Testcase) !void {
    const head = try std.fmt.allocPrint(arena, "test \"{f}\" {{\n", .{
        std.zig.fmtString(testcase.name),
    });
    try output.appendSlice(head);

    switch (testcase.result) {
        .skip => {
            try output.appendSlice(skip_test_template);
        },
        .none => {
            const body = try std.fmt.allocPrint(arena, no_output_template, .{
                testcase.path,
            });
            try output.appendSlice(body);
        },
        .expected_output_path => {
            const body = try std.fmt.allocPrint(arena, expect_file_template, .{
                testcase.path,
                testcase.result.expected_output_path,
            });
            try output.appendSlice(body);
        },
        .error_expected => {
            const body = try std.fmt.allocPrint(arena, expect_err_template, .{
                testcase.path,
            });
            try output.appendSlice(body);
        },
    }

    try output.appendSlice("}\n\n");
}

fn canAccess(dir: fs.Dir, file_path: []const u8) bool {
    if (dir.access(file_path, .{})) {
        return true;
    } else |_| {
        return false;
    }
}
