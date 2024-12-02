//! Extensible Markup Language (XML) 1.0
//! [(Fifth Edition)](http://www.w3.org/TR/2008/REC-xml-20081126)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const razdaz = @import("razdaz");
const ops = razdaz.op;

fn Decoder(comptime ReaderType: type, comptime buffer_size: usize) type {
    const Serial = razdaz.ReaderDecoder(ReaderType, buffer_size);
    return struct {
        serial: Serial,

        const Self = @This();

        pub fn fromReader(allocator: Allocator, reader: ReaderType) Self {
            return .{ .serial = razdaz.readerDecoder(allocator, reader, buffer_size) };
        }

        // [22] prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)?
        pub fn skipProlog(self: *Self) !void {
            try self.skipXmlDecl();
        }

        // [23] XMLDecl      ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'
        // [24] VersionInfo  ::= S 'version' Eq ("'" VersionNum "'" | '"' VersionNum '"')
        // [25] Eq           ::= S? '=' S?
        // [26] VersionNum   ::= '1.' [0-9]+
        // [80] EncodingDecl ::= S 'encoding' Eq ('"' EncName '"' | "'" EncName "'" )
        // [81] EncName      ::= [A-Za-z] ([A-Za-z0-9._] | '-')*
        // [32] SDDecl       ::= S 'standalone' Eq (("'" ('yes' | 'no') "'") | ('"' ('yes' | 'no') '"'))
        pub fn skipXmlDecl(self: *Self) !void {
            try self.serial.skip(ops.matchString("<?xml"));
            try self.serial.skip(ops.repeatMin(1, ops.matchWhitespace));

            try self.serial.skip(ops.matchString("version"));
            var quote = try self.skipEqlQuote();
            try self.serial.skip(ops.matchString("1."));
            try self.serial.skip(ops.repeatMin(1, ops.matchDigit));
            try quote.end();
            try self.serial.skip(ops.repeatWhile(ops.matchWhitespace));

            var part = try self.serial.peek(ops.matchAnyString(&.{ "?>", "encoding", "standalone" }));

            if (mem.eql(u8, "encoding", part.view())) {
                part.commitAndFree();
                quote = try self.skipEqlQuote();
                try self.serial.skip(ops.matchAlphabet);
                try self.serial.skip(ops.repeatWhile(ops.matchCharCompound(.{
                    .digit = true,
                    .lowercase = true,
                    .uppercase = true,
                    .other = "._-",
                })));
                try quote.end();

                try self.serial.skip(ops.repeatWhile(ops.matchWhitespace));
                part = try self.serial.peek(ops.matchAnyString(&.{ "?>", "standalone" }));
            }

            if (mem.eql(u8, "standalone", part.view())) {
                part.commitAndFree();
                quote = try self.skipEqlQuote();
                try self.serial.skip(ops.matchAnyString(&.{ "yes", "no" }));
                try quote.end();

                try self.serial.skip(ops.repeatWhile(ops.matchWhitespace));
                try self.serial.skip(ops.matchString("?>"));
                return;
            }

            // `?>`
            part.commitAndFree();
        }
    };
}

test Decoder {
    var buffer = std.io.fixedBufferStream(
        \\<?xml version="1.0" encoding="UTF-8"?>
    );
    const br = buffer.reader();
    var reader = Decoder(@TypeOf(br), 4096).fromReader(test_alloc, br);

    try reader.skipProlog();
}

/// Longest HTML entity: `CounterClockwiseContourIntegral`
/// https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references
const MAX_ENTITY_LEN = 31;

const escapeEntity = razdaz.Operator.define(escapeEntityMatcher, .{
    .scratch_hint = .max(2 + MAX_ENTITY_LEN), // 2 for `&` and `;`
    .resolve = razdaz.Resolver.define(.fail, escapeEntityResolver),
});

fn escapeEntityMatcher(i: usize, char: u8) razdaz.Matcher.Verdict {
    return matcher: switch (i) {
        0 => if (char == '&') .next else .invalid,
        1 => if (char == '#') .next else continue :matcher 2,
        2...(1 + MAX_ENTITY_LEN) => switch (char) {
            '0'...'9', 'a'...'z', 'A'...'Z' => .next,
            ';' => .done_include,
            else => .invalid,
        },
        else => .invalid,
    };
}

fn escapeEntityResolver(s: []const u8) ?u8 {
    if (s[1] != '#') {
        const code = s[1 .. s.len - 1];
        if (mem.eql(u8, "lt", code)) return '<';
        if (mem.eql(u8, "gt", code)) return '>';
        if (mem.eql(u8, "amp", code)) return '&';
        if (mem.eql(u8, "apos", code)) return '\'';
        if (mem.eql(u8, "quot", code)) return '"';
        return null;
    } else if (s[2] == 'x') {
        const num = s[3 .. s.len - 1];
        return std.fmt.parseInt(u8, num, 16) catch blk: {
            @branchHint(.unlikely);
            break :blk null;
        };
    } else {
        const num = s[2 .. s.len - 1];
        return std.fmt.parseInt(u8, num, 10) catch blk: {
            @branchHint(.unlikely);
            break :blk null;
        };
    }
}

test escapeEntity {
    try razdaz.testing.expectEvaluate(escapeEntity, "&#60;", '<', 5);
    try razdaz.testing.expectEvaluate(escapeEntity, "&#x3C;", '<', 6);
    try razdaz.testing.expectEvaluate(escapeEntity, "&lt;", '<', 4);
    try razdaz.testing.expectEvaluate(escapeEntity, "&gt;", '>', 4);
    try razdaz.testing.expectEvaluate(escapeEntity, "&amp;", '&', 5);
    try razdaz.testing.expectEvaluate(escapeEntity, "&apos;", '\'', 6);
    try razdaz.testing.expectEvaluate(escapeEntity, "&quot;", '"', 6);

    try razdaz.testing.expectFail(escapeEntity, "&;");
    try razdaz.testing.expectFail(escapeEntity, "&#;");
    try razdaz.testing.expectFail(escapeEntity, "&#x;");
    try razdaz.testing.expectFail(escapeEntity, "&UNDEF;");
}
