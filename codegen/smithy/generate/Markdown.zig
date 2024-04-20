//! Generate Markdown formatted content.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const assert = std.debug.assert;
const StackWriter = @import("../utils/StackWriter.zig");
const WriterList = StackWriter.List;
const Zig = @import("Zig.zig");

const Self = @This();

writer: *StackWriter,
is_empty: bool = true,

/// Call `end()` to complete the Markdown content and deinit.
pub fn init(writer: *StackWriter) Self {
    return .{ .writer = writer };
}

/// Complete the Markdown content and deinit.
pub fn end(self: *Self) !void {
    try self.writer.deinit();
    self.* = undefined;
}

fn writeAll(self: *Self, text: []const u8) !void {
    if (self.is_empty) {
        self.is_empty = false;
        try self.writer.prefixedAll(text);
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

    try writer.deinit();
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

    try writer.deinit();
    try testing.expectEqualStrings("0x6C\n\n0x6D", buffer.items);
}

pub fn paragraph(self: *Self, text: []const u8) !void {
    try self.writeAll(text);
}

test "paragraph" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    defer buffer.deinit();

    var md = init(&writer);
    try md.paragraph("foo.");

    try writer.deinit();
    try testing.expectEqualStrings("foo.", buffer.items);
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

    try writer.deinit();
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
        .identifier = "foo",
        .type = .{ .raw = "u8" },
    });
    try code.end();

    try writer.deinit();
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
        const current = self.writer.options.prefix;
        const scope = if (self.ordered) blk: {
            const prefix = if (ordered) "  " else "  - ";
            break :blk try self.writer.appendPrefix(prefix);
        } else blk: {
            var buffer: [64]u8 = undefined;
            @memcpy(buffer[0..current.len], self.writer.options.prefix);
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
        try self.writer.deinit();
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

    try writer.deinit();
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

    try writer.deinit();
    try testing.expectEqualStrings(
        \\| Foo | Bar | Baz |
        \\|----:|:---:|:----|
        \\| 17 | 18 | 19 |
        \\| 27 | 28 | 29 |
        \\| 37 | 38 | 39 |
    , buffer.items);
}
