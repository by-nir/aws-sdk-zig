//! Generate Markdown formatted content.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const assert = std.debug.assert;
const StackWriter = @import("../utils/StackWriter.zig");
const WriterList = StackWriter.List;
const Zig = @import("Zig.zig");

// TODO: Inline text styling & links
// TODO: Respect soft-/hard-guidelines

const Self = @This();

writer: *StackWriter,
is_empty: bool = true,

/// Call `end()` to complete the Markdown content and deinit.
pub fn init(writer: *StackWriter) Self {
    return .{ .writer = writer };
}

/// Complete the Markdown content and deinit.
/// **This will also deinit the writer.**
pub fn end(self: *Self) !void {
    try self.writer.end();
    self.* = undefined;
}

fn writeAll(self: *Self, text: []const u8) !void {
    if (self.is_empty) {
        self.is_empty = false;
        try self.writer.writeFmt(
            "{s}{s}",
            .{ mem.trimLeft(u8, self.writer.options.line_prefix, " "), text },
        );
    } else {
        try self.writer.lineBreak(1);
        try self.writer.lineAll(text);
    }
}

test "writeAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    try md.writeAll("foo");
    try md.writeAll("bar");

    try writer.end();
    try testing.expectEqualStrings("foo\n\nbar", buffer.items);
}

fn writeFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    if (self.is_empty) {
        self.is_empty = false;
        try self.writer.prefixedFmt(format, args);
    } else {
        try self.writer.lineBreak(1);
        try self.writer.lineFmt(format, args);
    }
}

test "writeFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    try md.writeFmt("0x{X}", .{108});
    try md.writeFmt("0x{X}", .{109});

    try writer.end();
    try testing.expectEqualStrings("0x6C\n\n0x6D", buffer.items);
}

pub fn paragraph(self: *Self, text: []const u8) !void {
    try self.writeAll(text);
}

pub fn paragraphFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.writeFmt(format, args);
}

test "paragraph" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    try md.paragraph("foo.");
    try md.paragraphFmt("{s}.", .{"bar"});

    try writer.end();
    try testing.expectEqualStrings("foo.\n\nbar.", buffer.items);
}

const HEADER_PREFIX = "### ";
pub fn header(self: *Self, level: u8, text: []const u8) !void {
    assert(level > 0 and level <= 3);
    const prefix = HEADER_PREFIX[3 - level .. 4];
    try self.writeFmt("{s}{s}", .{ prefix, text });
}

test "header" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    try md.header(2, "Foo");

    try writer.end();
    try testing.expectEqualStrings("## Foo", buffer.items);
}

/// Call `end()` to complete the code block.
pub fn codeblock(self: *Self) !Zig {
    try self.writeAll("```zig\n");
    const scope = try self.writer.appendPrefix("");
    try scope.deferLineAll(.parent, "```");
    return try Zig.init(scope, null);
}

test "codeblock" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    var code = try md.codeblock();
    _ = try code.field(.{
        .name = "foo",
        .type = .{ .raw = "u8" },
    });
    try code.end();

    try writer.end();
    try testing.expectEqualStrings(
        \\```zig
        \\foo: u8,
        \\```
    , buffer.items);
}

/// Call `end()` to complete the list.
pub fn list(self: *Self, ordered: bool) !List {
    if (self.is_empty) {
        self.is_empty = false;
        const prefix = if (ordered) "" else "- ";
        const scope = try self.writer.appendPrefix(prefix);
        return List.init(scope, ordered, true);
    } else {
        try self.writer.lineBreak(1);
        const prefix = if (ordered) "  " else "  - ";
        const scope = try self.writer.appendPrefix(prefix);
        return List.init(scope, ordered, false);
    }
}

pub const List = struct {
    writer: *StackWriter,
    ordered: bool,
    index: u16,

    fn init(writer: *StackWriter, ordered: bool, is_empty: bool) List {
        return .{
            .writer = writer,
            .ordered = ordered,
            .index = if (is_empty) 0 else 1,
        };
    }

    pub fn item(self: *List, text: []const u8) !void {
        assert(self.index <= std.math.maxInt(u16));
        if (self.index == 0) {
            self.index = 1;
            if (self.ordered) {
                try self.writer.prefixedFmt("{d}. {s}", .{ self.index, text });
            } else {
                try self.writer.prefixedAll(text);
            }
        } else if (self.ordered) {
            try self.writer.lineFmt("{d}. {s}", .{ self.index, text });
        } else {
            try self.writer.lineAll(text);
        }
        self.index += 1;
    }

    /// Call `end()` to complete the sub-list.
    pub fn list(self: *List, ordered: bool) !List {
        const current = self.writer.options.line_prefix;
        const scope = if (self.ordered) blk: {
            const prefix = if (ordered) "  " else "  - ";
            break :blk try self.writer.appendPrefix(prefix);
        } else blk: {
            var buffer: [64]u8 = undefined;
            @memcpy(buffer[0..current.len], self.writer.options.line_prefix);
            buffer[current.len - 2] = ' ';
            if (ordered) {
                break :blk try self.writer.replacePrefix(buffer[0..current.len]);
            } else {
                @memcpy(buffer[current.len..][0..2], "- ");
                break :blk try self.writer.replacePrefix(buffer[0 .. current.len + 2]);
            }
        };
        return List.init(scope, ordered, false);
    }

    pub fn end(self: *List) !void {
        try self.writer.end();
    }
};

test "list" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    var ls = try md.list(true);
    try ls.item("foo");

    var sub = try ls.list(false);
    try sub.item("bar");
    try sub.item("baz");

    var sub2 = try sub.list(true);
    try sub2.item("108");
    try sub2.item("109");
    try sub2.end();

    try sub.end();

    try ls.item("qux");
    try ls.end();

    try writer.end();
    try testing.expectEqualStrings(
        \\1. foo
        \\  - bar
        \\  - baz
        \\    1. 108
        \\    2. 109
        \\2. qux
    , buffer.items);
}

pub fn table(self: *Self, columns: []const Table.Column) !Table {
    assert(columns.len > 1 and columns.len <= 255);
    try self.writeFmt("| {} |", .{WriterList(Table.Column){
        .items = columns,
        .delimiter = " | ",
    }});

    try self.writer.lineAll("|");
    for (columns) |col| {
        try col.separator(self.writer);
    }

    return Table.init(self.writer, columns.len);
}

pub const Table = struct {
    writer: *StackWriter,
    coulmns: usize,

    fn init(writer: *StackWriter, coulmns: usize) Table {
        return .{ .writer = writer, .coulmns = coulmns };
    }

    pub fn row(self: Table, cells: []const []const u8) !void {
        assert(self.coulmns == cells.len);
        try self.writer.lineFmt("| {s} |", .{WriterList([]const u8){
            .items = cells,
            .delimiter = " | ",
        }});
    }

    pub const Column = struct {
        header: []const u8,
        alignment: Align = .center,

        pub const Align = enum { center, left, right };

        pub fn format(self: Column, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll(self.header);
        }

        fn separator(self: Column, writer: *StackWriter) !void {
            switch (self.alignment) {
                .center => {
                    try writer.writeByte(':');
                    try writer.writeNByte('-', self.header.len);
                    try writer.writeByte(':');
                },
                .left => {
                    try writer.writeByte(':');
                    try writer.writeNByte('-', self.header.len + 1);
                },
                .right => {
                    try writer.writeNByte('-', self.header.len + 1);
                    try writer.writeByte(':');
                },
            }
            try writer.writeByte('|');
        }
    };
};

test "table" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    const tb = try md.table(&.{
        .{
            .header = "Foo",
            .alignment = .right,
        },
        .{ .header = "Bar" },
        .{
            .header = "Baz",
            .alignment = .left,
        },
    });
    try tb.row(&.{ "17", "18", "19" });
    try tb.row(&.{ "27", "28", "29" });
    try tb.row(&.{ "37", "38", "39" });

    try writer.end();
    try testing.expectEqualStrings(
        \\| Foo | Bar | Baz |
        \\|----:|:---:|:----|
        \\| 17 | 18 | 19 |
        \\| 27 | 28 | 29 |
        \\| 37 | 38 | 39 |
    , buffer.items);
}

const HtmlBlock = union(enum) {
    none,
    paragraph,
    list: List,
    list_item: List,
};

const HtmlStyle = union(enum) {
    none,
    bold,
    italic,
    code,
    anchor: []const u8,
};
const html_map_style = std.StaticStringMap(std.meta.Tag(HtmlStyle)).initComptime(
    .{ .{ "b", .bold }, .{ "strong", .bold }, .{ "i", .italic }, .{ "em", .italic }, .{ "code", .code }, .{ "a", .anchor } },
);

/// Write Markdown source using an **extremely naive and partial** Markdown parser.
pub fn writeSource(self: *Self, source: []const u8) !void {
    var active_block: HtmlBlock = .none;
    var active_style: HtmlStyle = .none;
    var tokens = mem.tokenizeScalar(u8, source, '\n');
    outer: while (tokens.next()) |token_full| {
        var token = mem.trimLeft(u8, token_full, &std.ascii.whitespace);
        var line_start = true;
        if (token.len == 0) {
            active_style = .none;
            if (active_block != .list_item and active_block != .list) active_block = .none;
            continue :outer;
        }

        inner: while (token.len > 0) {
            token = mem.trimRight(u8, token, &std.ascii.whitespace);
            // Process tag
            if (token.len >= 3) if (mem.indexOfScalar(u8, token, '<')) |tag_start| {
                const is_close = token[1] == '/';
                const start_pad: usize = if (is_close) 2 else 1;
                if (mem.indexOfAnyPos(u8, token, tag_start + start_pad, " />")) |tag_end| {
                    // Emit previous text
                    if (tag_start > 0) {
                        try self.htmlWriteText(&active_block, &line_start, token[0..tag_start]);
                        token = token[tag_start..token.len];
                    }

                    // Extract tag name
                    const tag_name = token[start_pad .. tag_end - tag_start];
                    if (tag_name.len == 0) continue :inner;

                    var did_process = true;
                    if (html_map_style.get(tag_name)) |tag| {
                        switch (tag) {
                            .none => unreachable,
                            inline .italic, .bold, .code => |g| {
                                if (is_close) {
                                    assert(active_style == g);
                                    active_style = .none;
                                } else {
                                    assert(active_style == .none);
                                    active_style = g;
                                }
                                try self.writer.writeAll(switch (g) {
                                    .italic => "_",
                                    .bold => "**",
                                    .code => "`",
                                    else => unreachable,
                                });
                            },
                            .anchor => {
                                if (is_close) {
                                    assert(active_style == .anchor);
                                    try self.writer.writeFmt("]({s})", .{active_style.anchor});
                                    active_style = .none;
                                } else if (mem.indexOfPos(u8, token, 3, "href=\"")) |href_start| {
                                    assert(active_style == .none);
                                    if (mem.indexOfPos(u8, token, href_start + 6, "\">")) |href_end| {
                                        try self.writer.writeAll("[");
                                        active_style = .{ .anchor = token[href_start + 6 .. href_end] };
                                    }
                                } else {
                                    did_process = false;
                                }
                            },
                        }
                    } else if (mem.eql(u8, "p", tag_name)) {
                        if (is_close) switch (active_block) {
                            .paragraph => active_block = .none,
                            .list => {
                                try active_block.list.end();
                                active_block = .none;
                            },
                            else => {},
                        };
                    } else if (mem.eql(u8, "ul", tag_name)) {
                        if (is_close) {
                            try active_block.list.end();
                            active_block = .none;
                        } else {
                            active_block = .{ .list = try self.list(false) };
                        }
                    } else if (mem.eql(u8, "ol", tag_name)) {
                        if (is_close) {
                            try active_block.list.end();
                            active_block = .none;
                        } else {
                            active_block = .{ .list = try self.list(true) };
                        }
                    } else if (mem.eql(u8, "li", tag_name)) {
                        switch (active_block) {
                            .list => {
                                if (is_close) {
                                    try active_block.list.end();
                                    active_block = .none;
                                }
                            },
                            .list_item => active_block = .{ .list = active_block.list_item },
                            else => did_process = false,
                        }
                    } else {
                        did_process = false;
                    }

                    // Consume tag
                    if (did_process) {
                        const end_caret = tag_end - tag_start;
                        token = if (token[end_caret] == '>')
                            token[1 + end_caret .. token.len]
                        else if (mem.indexOfScalarPos(u8, token, 1 + end_caret, '>')) |i|
                            token[1 + i .. token.len]
                        else
                            unreachable;
                        continue :inner;
                    }
                }
            };

            // Emit remaining text
            try self.htmlWriteText(&active_block, &line_start, token);
            token = &.{};
        }
    }
}

fn htmlWriteText(self: *Self, block: *HtmlBlock, line_start: *bool, value: []const u8) !void {
    switch (block.*) {
        .none => {
            try self.writeAll(value);
            block.* = .paragraph;
            line_start.* = false;
        },
        .paragraph, .list_item => {
            if (line_start.*) {
                line_start.* = false;
                try self.writer.writeFmt(" {s}", .{value});
            } else {
                try self.writer.writeAll(value);
            }
        },
        .list => {
            try block.list.item(value);
            block.* = .{ .list_item = block.list };
            line_start.* = false;
        },
    }
}

test "writeSource" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    try md.writeSource("    <p>Foo.</p>\n    <p>Bar baz\n    qux.</p>");
    try md.end();
    try testing.expectEqualStrings(
        \\Foo.
        \\
        \\Bar baz qux.
    , buffer.items);

    buffer.clearRetainingCapacity();
    md = init(&writer);
    try md.writeSource("<p>Inline: <a href=\"#\">foo\n    106</a>, <i>bar \n    107</i>, <b>baz \n    108</b>, <code>qux \n    109</code>.</p>");
    try md.end();
    try testing.expectEqualStrings(
        \\Inline: [foo 106](#), _bar 107_, **baz 108**, `qux 109`.
    , buffer.items);

    buffer.clearRetainingCapacity();
    md = init(&writer);
    try md.writeSource("<ul>\n<li>\nFoo 106\n</li>\n<li>Bar\n107</li>\n<li><p>Baz 108</p></li>\n<li>\n<p>\nQux\n109</p></li></ul>");
    try md.end();
    try testing.expectEqualStrings(
        \\- Foo 106
        \\- Bar 107
        \\- Baz 108
        \\- Qux 109
    , buffer.items);
}
