const Tokenizer = @This();

const std = @import("std");
const log = std.log.scoped(.tokenizer);
const testing = std.testing;

buffer: []const u8,
index: usize = 0,
literal_type: LiteralType = .None,

const LiteralType = enum {
    None,
    SingleQuote,
    DoubleQuote,
};

pub const Token = struct {
    id: Id,
    start: usize,
    end: usize,
    // Count of spaces/tabs.
    // Only active for .Space and .Tab tokens.
    count: ?usize = null,

    pub const Id = enum {
        Eof,

        NewLine,
        DocStart, // ---
        DocEnd, // ...
        SeqItemInd, // -
        MapValueInd, // :
        FlowMapStart, // {
        FlowMapEnd, // }
        FlowSeqStart, // [
        FlowSeqEnd, // ]

        Comma,
        Space,
        Tab,
        Comment, // #
        Alias, // *
        Anchor, // &
        Tag, // !
        SingleQuote, // '
        DoubleQuote, // "

        Literal,
    };
};

pub const TokenIndex = usize;

pub const TokenIterator = struct {
    buffer: []const Token,
    pos: TokenIndex = 0,

    pub fn next(self: *TokenIterator) Token {
        const token = self.buffer[self.pos];
        self.pos += 1;
        return token;
    }

    pub fn peek(self: TokenIterator) ?Token {
        if (self.pos >= self.buffer.len) return null;
        return self.buffer[self.pos];
    }

    pub fn reset(self: *TokenIterator) void {
        self.pos = 0;
    }

    pub fn seekTo(self: *TokenIterator, pos: TokenIndex) void {
        self.pos = pos;
    }

    pub fn seekBy(self: *TokenIterator, offset: isize) void {
        const new_pos = @bitCast(isize, self.pos) + offset;
        if (new_pos < 0) {
            self.pos = 0;
        } else {
            self.pos = @intCast(usize, new_pos);
        }
    }
};

pub fn next(self: *Tokenizer) Token {
    var result = Token{
        .id = .Eof,
        .start = self.index,
        .end = undefined,
    };

    var state: union(enum) {
        Start,
        NewLine,
        Space: usize,
        Tab: usize,
        Hyphen: usize,
        Dot: usize,
        SingleQuote,
        Literal,
        EscapeSeq,
    } = .Start;

    while (self.index < self.buffer.len) : (self.index += 1) {
        const c = self.buffer[self.index];
        switch (state) {
            .Start => switch (c) {
                ' ' => {
                    state = .{ .Space = 1 };
                },
                '\t' => {
                    state = .{ .Tab = 1 };
                },
                '\n' => {
                    result.id = .NewLine;
                    self.index += 1;
                    break;
                },
                '\r' => {
                    state = .NewLine;
                },
                '-' => {
                    state = .{ .Hyphen = 1 };
                },
                '.' => {
                    state = .{ .Dot = 1 };
                },
                ',' => {
                    result.id = .Comma;
                    self.index += 1;
                    break;
                },
                '#' => {
                    result.id = .Comment;
                    self.index += 1;
                    break;
                },
                '*' => {
                    result.id = .Alias;
                    self.index += 1;
                    break;
                },
                '&' => {
                    result.id = .Anchor;
                    self.index += 1;
                    break;
                },
                '!' => {
                    result.id = .Tag;
                    self.index += 1;
                    break;
                },
                '\'' => {
                    result.id = .SingleQuote;
                    self.literal_type = if (self.literal_type == .SingleQuote) .None else .SingleQuote;
                    self.index += 1;
                    break;
                },
                '"' => {
                    result.id = .DoubleQuote;
                    self.literal_type = if (self.literal_type == .DoubleQuote) .None else .DoubleQuote;
                    self.index += 1;
                    break;
                },
                '[' => {
                    result.id = .FlowSeqStart;
                    self.index += 1;
                    break;
                },
                ']' => {
                    result.id = .FlowSeqEnd;
                    self.index += 1;
                    break;
                },
                ':' => {
                    result.id = .MapValueInd;
                    self.index += 1;
                    break;
                },
                '{' => {
                    result.id = .FlowMapStart;
                    self.index += 1;
                    break;
                },
                '}' => {
                    result.id = .FlowMapEnd;
                    self.index += 1;
                    break;
                },
                '\\' => {
                    state = .EscapeSeq;
                },
                else => {
                    state = .Literal;
                },
            },
            .Space => |*count| switch (c) {
                ' ' => {
                    count.* += 1;
                },
                else => {
                    result.id = .Space;
                    result.count = count.*;
                    break;
                },
            },
            .Tab => |*count| switch (c) {
                ' ' => {
                    count.* += 1;
                },
                else => {
                    result.id = .Tab;
                    result.count = count.*;
                    break;
                },
            },
            .NewLine => switch (c) {
                '\n' => {
                    result.id = .NewLine;
                    self.index += 1;
                    break;
                },
                else => {}, // TODO this should be an error condition
            },
            .Hyphen => |*count| switch (c) {
                ' ' => {
                    result.id = .SeqItemInd;
                    self.index += 1;
                    break;
                },
                '-' => {
                    count.* += 1;

                    if (count.* == 3) {
                        result.id = .DocStart;
                        self.index += 1;
                        break;
                    }
                },
                else => {
                    state = .Literal;
                },
            },
            .Dot => |*count| switch (c) {
                '.' => {
                    count.* += 1;

                    if (count.* == 3) {
                        result.id = .DocEnd;
                        self.index += 1;
                        break;
                    }
                },
                else => {
                    state = .Literal;
                },
            },
            .SingleQuote => switch (c) {
                '\'' => {
                    state = .Literal;
                },
                else => { // This was not an escaped single quote. Go back for the literal.
                    self.index -= 1;
                    result.id = .Literal;
                    break;
                },
            },
            .Literal => switch (c) {
                '\'' => {
                    if (self.literal_type == .SingleQuote) {
                        state = .SingleQuote;
                    }
                },
                '\\' => {
                    if (self.literal_type == .DoubleQuote) {
                        state = .EscapeSeq;
                    }
                },
                '\r', '\n', ' ', '"', ',', ':', ']', '}' => {
                    result.id = .Literal;
                    break;
                },
                else => {
                    result.id = .Literal;
                },
            },
            .EscapeSeq => {
                state = .Literal;
            },
        }
    }

    if (self.index >= self.buffer.len) {
        switch (state) {
            .Literal => {
                result.id = .Literal;
            },
            .SingleQuote => {
                // We are at the Eof while checking for an escaped single quote. It wasn't, so go back for the literal.
                result.id = .Literal;
                self.index -= 1;
            },
            else => {},
        }
    }

    result.end = self.index;

    log.debug("{any}", .{result});
    log.debug("    | {s}", .{self.buffer[result.start..result.end]});

    return result;
}

fn testExpected(source: []const u8, expected: []const Token.Id) !void {
    var tokenizer = Tokenizer{
        .buffer = source,
    };

    for (expected) |exp| {
        const token = tokenizer.next();
        try testing.expectEqual(exp, token.id);
    }
}

test "empty doc" {
    try testExpected("", &[_]Token.Id{.Eof});
}

test "empty doc with explicit markers" {
    try testExpected(
        \\---
        \\...
    , &[_]Token.Id{
        .DocStart, .NewLine, .DocEnd, .Eof,
    });
}

test "sequence of values" {
    try testExpected(
        \\- 0
        \\- 1
        \\- 2
    , &[_]Token.Id{
        .SeqItemInd,
        .Literal,
        .NewLine,
        .SeqItemInd,
        .Literal,
        .NewLine,
        .SeqItemInd,
        .Literal,
        .Eof,
    });
}

test "sequence of sequences" {
    try testExpected(
        \\- [ val1, val2]
        \\- [val3, val4 ]
    , &[_]Token.Id{
        .SeqItemInd,
        .FlowSeqStart,
        .Space,
        .Literal,
        .Comma,
        .Space,
        .Literal,
        .FlowSeqEnd,
        .NewLine,
        .SeqItemInd,
        .FlowSeqStart,
        .Literal,
        .Comma,
        .Space,
        .Literal,
        .Space,
        .FlowSeqEnd,
        .Eof,
    });
}

test "mappings" {
    try testExpected(
        \\key1: value1
        \\key2: value2
    , &[_]Token.Id{
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .NewLine,
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .Eof,
    });
}

test "inline mapped sequence of values" {
    try testExpected(
        \\key :  [ val1, 
        \\          val2 ]
    , &[_]Token.Id{
        .Literal,
        .Space,
        .MapValueInd,
        .Space,
        .FlowSeqStart,
        .Space,
        .Literal,
        .Comma,
        .Space,
        .NewLine,
        .Space,
        .Literal,
        .Space,
        .FlowSeqEnd,
        .Eof,
    });
}

test "part of tdb" {
    try testExpected(
        \\--- !tapi-tbd
        \\tbd-version:     4
        \\targets:         [ x86_64-macos ]
        \\
        \\uuids:
        \\  - target:          x86_64-macos
        \\    value:           F86CC732-D5E4-30B5-AA7D-167DF5EC2708
        \\
        \\install-name:    '/usr/lib/libSystem.B.dylib'
        \\...
    , &[_]Token.Id{
        .DocStart,
        .Space,
        .Tag,
        .Literal,
        .NewLine,
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .NewLine,
        .Literal,
        .MapValueInd,
        .Space,
        .FlowSeqStart,
        .Space,
        .Literal,
        .Space,
        .FlowSeqEnd,
        .NewLine,
        .NewLine,
        .Literal,
        .MapValueInd,
        .NewLine,
        .Space,
        .SeqItemInd,
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .NewLine,
        .Space,
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .NewLine,
        .NewLine,
        .Literal,
        .MapValueInd,
        .Space,
        .SingleQuote,
        .Literal,
        .SingleQuote,
        .NewLine,
        .DocEnd,
        .Eof,
    });
}

test "simple map typed" {
    try testExpected(
        \\a: 0
        \\b: hello there
        \\c: 'wait, what?'
    , &[_]Token.Id{
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .NewLine,
        .Literal,
        .MapValueInd,
        .Space,
        .Literal,
        .Space,
        .Literal,
        .NewLine,
        .Literal,
        .MapValueInd,
        .Space,
        .SingleQuote,
        .Literal,
        .Comma,
        .Space,
        .Literal,
        .SingleQuote,
        .Eof,
    });
}
