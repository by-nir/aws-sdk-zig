const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const md = @import("../md.zig");
const Writer = @import("../CodegenWriter.zig");

const log = std.log.scoped(.html_to_md);

const Tag = struct {
    kind: Kind,
    role: Role,
    len: usize,

    pub const Role = enum { open, close };

    pub const Kind = union(enum) {
        UNRECOGNIZED: []const u8,
        paragraph,
        list: md.List.Kind,
        list_item,
        anchor,
        bold,
        italic,
        code,
    };
};

/// Write Markdown source using an **extremely naive and partial** Markdown parser.
pub fn convert(allocator: Allocator, bld: *md.Document.Build, source: []const u8) !void {
    var tokens = mem.tokenizeAny(u8, source, &std.ascii.whitespace);
    while (tokens.next()) |token| {
        var remaining = token;
        inner: while (remaining.len > 0) {
            const open_idx = mem.indexOfScalar(u8, remaining, '<') orelse {
                log.warn("Missing root tag: `{s}`", .{token});
                return error.MissingRootTag;
            };
            const tag: Tag = extractTagAt(remaining, open_idx) orelse {
                log.warn("Missing root tag: `{s}`", .{token});
                return error.MissingRootTag;
            };

            remaining = remaining[tag.len..remaining.len];
            if (tag.kind == .UNRECOGNIZED) continue :inner;
            if (tag.role == .close) return error.UnexpectedClosingTag;

            remaining = switch (tag.kind) {
                .paragraph => try processParagraph(allocator, bld, &tokens, remaining),
                .list => |kind| try processList(allocator, bld, kind, &tokens, remaining),
                .UNRECOGNIZED => unreachable,
                else => return error.UnexpectedRootTag,
            };
        }
    }
}

fn processParagraph(
    allocator: Allocator,
    bld: *md.Document.Build,
    tokenizer: *mem.TokenIterator(u8, .any),
    initial: []const u8,
) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var remaining = if (initial.len > 0) initial else tokenizer.next() orelse "";
    if (try processFormattedText(
        bld.allocator,
        &buffer,
        &remaining,
        tokenizer,
        .paragraph,
    )) |formatted| {
        try bld.blocks.append(bld.allocator, .{ .paragraph = formatted });
    }

    if (remaining.len == 0) remaining = tokenizer.next() orelse "";
    return remaining;
}

fn processList(
    allocator: Allocator,
    bld: *md.Document.Build,
    kind: md.List.Kind,
    tokenizer: *mem.TokenIterator(u8, .any),
    initial: []const u8,
) ![]const u8 {
    var remaining = if (initial.len > 0) initial else tokenizer.next() orelse "";

    const context = .{ .allocator = allocator, .tokenizer = tokenizer, .remaining = &remaining };
    try bld.listWith(kind, context, struct {
        fn f(ctx: @TypeOf(context), b: *md.List.Build) !void {
            var buffer = std.ArrayList(u8).init(ctx.allocator);
            defer buffer.deinit();

            var pos: usize = 0;
            while (pos < ctx.remaining.len) {
                const tag = try consumeUntilTag(&buffer, ctx.tokenizer, ctx.remaining, &pos) orelse continue;
                switch (tag.kind) {
                    .list => |k| switch (tag.role) {
                        .open => {
                            // TODO
                            _ = k; // autofix
                            return error.UnsupportedNestedList;
                        },
                        .close => {
                            const text = try flushTextBuffer(&buffer, ctx.remaining, &pos, tag.len);
                            std.debug.assert(text == null);
                            return;
                        },
                    },
                    .list_item => {
                        if (tag.role == .close) return error.UnexpectedClosingTag;
                        const text = try flushTextBuffer(&buffer, ctx.remaining, &pos, tag.len);
                        std.debug.assert(text == null);

                        if (try processFormattedText(
                            b.allocator,
                            &buffer,
                            ctx.remaining,
                            ctx.tokenizer,
                            .list_item,
                        )) |formatted| {
                            try b.items.append(b.allocator, .{ .formated = formatted });
                        }
                        pos = 0;
                    },
                    else => return error.UnexpectedTag,
                }

                if (ctx.remaining.len == 0) ctx.remaining.* = ctx.tokenizer.next() orelse "";
            }
        }
    }.f);

    return remaining;
}

fn processFormattedText(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    remaining: *[]const u8,
    tokenizer: *mem.TokenIterator(u8, .any),
    comptime container: Tag.Kind,
) !?md.Formated {
    var segments = std.ArrayList(md.Formated.Segment).init(allocator);
    var interim_style: md.Formated.Style = undefined;
    errdefer segments.deinit();

    var pos: usize = 0;
    if (remaining.len == 0) remaining.* = tokenizer.next() orelse "";
    while (pos < remaining.len) {
        const tag = try consumeUntilTag(buffer, tokenizer, remaining, &pos) orelse continue;
        switch (tag.kind) {
            inline .italic, .bold, .code => |t, g| switch (tag.role) {
                .open => {
                    if (try flushTextBuffer(buffer, remaining, &pos, tag.len)) |s| {
                        try segments.append(.{ .text = s, .format = .plain });
                    }
                },
                .close => {
                    const style = @unionInit(md.Formated.Style, @tagName(g), t);
                    if (try flushTextBuffer(buffer, remaining, &pos, tag.len)) |s| {
                        try segments.append(.{ .text = s, .format = style });
                    }
                },
            },
            .anchor => switch (tag.role) {
                .open => {
                    if (try flushTextBuffer(buffer, remaining, &pos, tag.len)) |s| {
                        try segments.append(.{ .text = s, .format = .plain });
                    }

                    remaining.* = tokenizer.next() orelse return error.MissingHrefAttribute;
                    pos = 6 + (mem.indexOf(u8, remaining.*, "href=\"") orelse {
                        return error.MissingHrefAttribute;
                    });
                    const href_end = mem.indexOfPos(u8, remaining.*, pos, "\">") orelse {
                        return error.MissingHrefAttribute;
                    };

                    interim_style = .{ .link = remaining.*[pos..href_end] };
                    remaining.* = remaining.*[href_end + 2 .. remaining.len];
                    pos = 0;
                },
                .close => {
                    if (try flushTextBuffer(buffer, remaining, &pos, tag.len)) |s| {
                        try segments.append(.{ .text = s, .format = interim_style });
                    }
                },
            },
            container => {
                if (tag.role == .open) return error.UnexpectedNestedContainer;
                if (try flushTextBuffer(buffer, remaining, &pos, tag.len)) |s| {
                    try segments.append(.{ .text = s, .format = .plain });
                }
                return if (segments.items.len > 0) .{
                    .segments = try segments.toOwnedSlice(),
                } else null;
            },
            // Ignore non-container tags, but consume their text
            else => try appendTextBuffer(buffer, remaining, &pos, tag.len),
        }

        if (remaining.len == 0) remaining.* = tokenizer.next() orelse "";
    }

    return null;
}

fn consumeUntilTag(
    buffer: *std.ArrayList(u8),
    tokenizer: *mem.TokenIterator(u8, .any),
    remaining: *[]const u8,
    pos: *usize,
) !?Tag {
    const open_idx = mem.indexOfScalarPos(u8, remaining.*, pos.*, '<') orelse {
        // No special action
        try padBuffer(buffer, remaining.*);
        try buffer.appendSlice(remaining.*);
        pos.* = 0;
        remaining.* = tokenizer.*.next() orelse "";
        return null;
    };

    pos.* = open_idx;
    return extractTagAt(remaining.*, open_idx) orelse {
        pos.* += 1;
        return null;
    };
}

fn padBuffer(buffer: *std.ArrayList(u8), text: []const u8) !void {
    if (buffer.items.len == 0 or text.len == 0) return;
    try buffer.append(' ');
}

fn appendTextBuffer(buffer: *std.ArrayList(u8), remaining: *[]const u8, pos: *usize, tag_len: usize) !void {
    const text = remaining.*[0..pos.*];
    try padBuffer(buffer, text);
    try buffer.appendSlice(text);
    remaining.* = remaining.*[pos.* + tag_len .. remaining.len];
    pos.* = 0;
}

fn flushTextBuffer(buffer: *std.ArrayList(u8), remaining: *[]const u8, pos: *usize, tag_len: usize) !?[]const u8 {
    const text = remaining.*[0..pos.*];
    try padBuffer(buffer, text);
    try buffer.appendSlice(text);
    remaining.* = remaining.*[pos.* + tag_len .. remaining.len];
    pos.* = 0;
    return if (buffer.items.len > 0) try buffer.toOwnedSlice() else null;
}

fn extractTagAt(string: []const u8, pos: usize) ?Tag {
    var idx = pos;
    if (idx + 1 == string.len) return null;
    const is_close: bool = if (string[idx + 1] == '/') blk: {
        idx += 1;
        if (!hasRemaining(string, idx, 2)) return null;
        break :blk true;
    } else false;

    const name_start = string[idx + 1 ..];

    var len: usize = 0;
    var kind: Tag.Kind = undefined;
    if (hasRemaining(string, idx, 2) and name_start[1] == '>') {
        len = 3;
        kind = switch (name_start[0]) {
            'p' => .paragraph,
            'i' => .italic,
            'b' => .bold,
            'a' => if (!is_close) {
                log.warn("Anchor missing href attribute", .{});
                return null;
            } else .anchor,
            else => return null,
        };
    } else if (hasRemaining(string, idx, 3) and name_start[2] == '>') {
        const name = name_start[0..2];
        len = 4;
        kind = if (mem.eql(u8, "ul", name))
            .{ .list = .unordered }
        else if (mem.eql(u8, "ol", name))
            .{ .list = .ordered }
        else if (mem.eql(u8, "li", name))
            .list_item
        else if (mem.eql(u8, "em", name))
            .italic
        else
            return null;
    } else if (name_start[0] == 'a' and hasRemaining(string, idx, 0)) {
        len = 2;
        kind = .anchor;
    } else if (hasRemaining(string, idx, 5) and mem.eql(u8, "code>", name_start[0..5])) {
        len = 6;
        kind = .code;
    } else if (hasRemaining(string, idx, 7) and mem.eql(u8, "strong>", name_start[0..7])) {
        len = 8;
        kind = .bold;
    } else if (mem.indexOfAnyPos(u8, string, idx + 1, "<>")) |close_idx| {
        if (string[close_idx] == '<') return null;
        const name = string[idx + 1 .. close_idx];
        if (!is_close) log.warn("Unrecognized tag: `<{s}>`", .{name});
        len = name.len + 2;
        kind = .{ .UNRECOGNIZED = name };
    } else {
        return null;
    }

    if (is_close) len += 1;
    return .{
        .kind = kind,
        .role = if (is_close) .close else .open,
        .len = len,
    };
}

fn hasRemaining(string: []const u8, after: usize, n: usize) bool {
    return string.len - after > n;
}

test "convert" {
    try expect("    <p>Foo.</p><p></p>\n    <p>Bar baz\n    <qux.</p>",
        \\Foo.
        \\
        \\Bar baz <qux.
    );

    try expect(
        "<p>Inline: <a href=\"#\">foo\n    106</a>, <i>bar \n    107</i>, <b>baz \n    108</b>, <code>qux \n    109</code>.</p>",
        "Inline: [foo 106](#), _bar 107_, **baz 108**, `qux 109`.",
    );

    try expect("<ul>\n<li>\nFoo 106\n</li>\n<li><code>Bar\n107</code></li>\n<li><p>Baz 108</p></li>\n<li>\nQux<p>\n109</p></li></ul>",
        \\- Foo 106
        \\- `Bar 107`
        \\- Baz 108
        \\- Qux 109
    );
}

fn expect(source: []const u8, expected: []const u8) !void {
    var build = md.Document.Build{ .allocator = test_alloc };
    errdefer build.deinit(test_alloc);

    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    try convert(arena.allocator(), &build, source);
    const doc = try build.consume();
    defer doc.deinit(test_alloc);
    try Writer.expectValue(expected, doc);
}
