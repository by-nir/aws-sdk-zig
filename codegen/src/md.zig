const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const dcl = @import("utils/declarative.zig");
const StackChain = dcl.StackChain;
const InferCallback = dcl.InferCallback;
const Cb = dcl.Callback;
const createCallback = dcl.callback;
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const zig = @import("zig.zig");
const Writer = @import("CodegenWriter.zig");
const source_tree = @import("source_tree.zig");

pub const html = @import("md/html.zig");

pub const ListKind = enum(u8) { unordered, ordered };
pub const ColumnAlign = enum(u8) { left, center, right };

pub const DocumentClosure = *const fn (*DocumentAuthor) anyerror!void;

// TODO: Support soft/hard width guidelines
pub fn authorDocument(
    allocator: Allocator,
    ctx: anytype,
    closure: Closure(@TypeOf(ctx), DocumentClosure),
) !Document {
    var author = try DocumentAuthor.init(allocator);
    errdefer author.deinit();
    try callClosure(ctx, closure, .{&author});
    return author.consume();
}

const Mark = enum(u64) {
    block_raw,
    block_comment,
    block_heading,
    block_paragraph,
    block_quote,
    block_list,
    block_list_item,
    block_table,
    block_table_column,
    block_table_row,
    block_table_cell,
    block_code,
    text_plain,
    text_italic,
    text_bold,
    text_bold_italic,
    text_code,
    text_link,

    pub fn is_inline(self: Mark) bool {
        return @intFromEnum(self) >= @intFromEnum(Mark.text_plain);
    }
};

const MarkTree = source_tree.SourceTree(Mark);
const MarkTreeAuthor = source_tree.SourceTreeAuthor(Mark);

const MarkHeading = struct {
    level: u8,
    text: []const u8,
};

const MAX_TABLE_COLUMNS = 16;

const MarkColumn = packed struct(u24) {
    aligns: ColumnAlign = .left,
    self_width: u8 = 0,
    dynamic_width: u8 = 0,
};

pub const Document = struct {
    tree: MarkTree,

    const INDENT = " " ** 4;

    pub fn author(allocator: Allocator) !DocumentAuthor {
        return DocumentAuthor.init(allocator);
    }

    pub fn deinit(self: Document, allocator: Allocator) void {
        self.tree.deinit(allocator);
    }

    pub fn write(self: Document, writer: *Writer) !void {
        var it = self.tree.iterate();
        if (it.next()) |node| try writeNode(node, writer);

        while (it.next()) |node| {
            try writeNodeLineBreak(writer);
            try writeNode(node, writer);
        }
    }

    fn writeNode(node: MarkTree.Node, writer: *Writer) anyerror!void {
        switch (node.tag) {
            .block_raw, .text_plain => try writer.appendString(node.payload([]const u8)),
            .text_italic => try writer.appendFmt("_{s}_", .{node.payload([]const u8)}),
            .text_bold => try writer.appendFmt("**{s}**", .{node.payload([]const u8)}),
            .text_bold_italic => try writer.appendFmt("***{s}***", .{node.payload([]const u8)}),
            .text_code => try writer.appendFmt("`{s}`", .{node.payload([]const u8)}),
            .text_link => {
                // TODO: [foo](href "title")
                try writer.appendChar('[');
                try writeNodeChildren(node, .inlined, writer);
                try writer.appendFmt("]({s})", .{node.payload([]const u8)});
            },
            .block_comment => try writer.appendFmt("<!-- {s} -->", .{node.payload([]const u8)}),
            .block_paragraph => try writeNodeChildren(node, .inlined, writer),
            .block_heading => {
                const heading = node.payload(MarkHeading);
                std.debug.assert(heading.level > 0 and heading.level <= 6);
                const prefix = "#######"[6 - heading.level .. 6];
                try writer.appendFmt("{s} {s}", .{ prefix, heading.text });
            },
            .block_quote => {
                try writer.pushIndent("> ");
                defer writer.popIndent();
                try writer.appendString("> ");
                try writeNodeChildren(node, .inlined, writer);
            },
            .block_code => {
                const code: *const zig.Container = @ptrFromInt(node.payload(usize));

                try writer.appendString("```zig\n");
                try code.write(writer);
                try writer.breakString("```");
            },
            .block_list => {
                const kind = node.payload(ListKind);

                var i: usize = 1;
                var items = node.iterate();
                while (items.next()) |item| {
                    if (i > 1) try writer.breakString("");
                    if (item.tag == .block_list) {
                        try writer.pushIndent(INDENT);
                        defer writer.popIndent();
                        try writer.appendString(INDENT);
                        try writeNode(item, writer);
                    } else {
                        switch (kind) {
                            .unordered => try writer.appendString("- "),
                            .ordered => try writer.appendFmt("{d}. ", .{i}),
                        }
                        try writeNodeChildren(item, .inlined_or_indent, writer);
                        i += 1;
                    }
                }
            },
            .block_table => {
                const col_len = node.payload(u8);

                const whitespace = " " ** 255;
                const separator = "-" ** 255;

                var widths: [MAX_TABLE_COLUMNS]u8 = undefined;

                // Header
                try writer.appendChar('|');
                for (0..col_len) |i| {
                    const col_node = node.child(i).?;
                    const column = col_node.payload(MarkColumn);
                    widths[i] = column.dynamic_width;
                    const padding = column.dynamic_width - column.self_width;

                    try writer.appendChar(' ');
                    try writeNodeChildren(col_node, .inlined, writer);
                    try writer.appendString(whitespace[0..padding]);
                    try writer.appendString(" |");
                }

                // Separator
                try writer.breakChar('|');
                for (0..col_len) |i| {
                    const item = node.child(i).?;
                    const column = item.payload(MarkColumn);
                    switch (column.aligns) {
                        .left => try writer.appendFmt(
                            ":{s}|",
                            .{separator[0 .. column.dynamic_width + 1]},
                        ),
                        .center => try writer.appendFmt(
                            ":{s}:|",
                            .{separator[0..column.dynamic_width]},
                        ),
                        .right => try writer.appendFmt(
                            "{s}:|",
                            .{separator[0 .. column.dynamic_width + 1]},
                        ),
                    }
                }

                // Rows
                var it = node.iterate();
                it.skip(col_len);
                while (it.next()) |row_node| {
                    try writer.breakChar('|');

                    var i: usize = 0;
                    var row = row_node.iterate();
                    while (row.next()) |cell_node| : (i += 1) {
                        const padding = widths[i] - cell_node.payload(u8);

                        try writer.appendChar(' ');
                        try writeNodeChildren(cell_node, .inlined, writer);
                        try writer.appendString(whitespace[0..padding]);
                        try writer.appendString(" |");
                    }
                }
            },
            else => return error.UnexpectedNodeTag,
        }
    }

    const Concat = enum { blocks, inlined, inlined_or_indent };
    fn writeNodeChildren(parent: MarkTree.Node, concat: Concat, writer: *Writer) !void {
        var inlined = false;
        var defer_pop_indent = false;

        var it = parent.iterate();
        if (it.next()) |node| {
            try writeNode(node, writer);

            switch (concat) {
                .blocks => try writer.breakEmpty(1),
                .inlined => inlined = node.tag.is_inline(),
                .inlined_or_indent => {
                    if (node.tag.is_inline()) {
                        inlined = true;
                    } else {
                        defer_pop_indent = true;
                        try writer.pushIndent(INDENT);
                    }
                },
            }
        }
        defer if (defer_pop_indent) writer.popIndent();

        if (inlined) {
            try writeNodeInlineSpace(writer, it.peek());
            while (it.next()) |node| {
                try writeNode(node, writer);
                try writeNodeInlineSpace(writer, it.peek());
            }
        } else {
            while (it.next()) |node| {
                try writeNodeLineBreak(writer);
                try writeNode(node, writer);
            }
        }
    }

    fn writeNodeLineBreak(writer: *Writer) !void {
        try writer.breakEmpty(1);
        try writer.breakString("");
    }

    fn writeNodeInlineSpace(writer: *Writer, next: ?MarkTree.Node) !void {
        const node = next orelse return;
        if (mem.indexOfScalar(u8, ".,;:?!", node.payload([]const u8)[0]) != null) return;

        try writer.appendChar(' ');
    }
};

test "Document: Raw" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_raw);
            errdefer node.deinit();
            try node.setPayload([]const u8, "foo");
            try node.seal();

            node = try tree.append(.block_raw);
            try node.setPayload([]const u8, "bar");
            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\foo
        \\
        \\bar
    , doc);
}

test "Document: Comment" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_comment);
            errdefer node.deinit();
            try node.setPayload([]const u8, "foo");
            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue("<!-- foo -->", doc);
}

test "Document: Paragraph & Text" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_paragraph);
            errdefer node.deinit();

            var child = try node.append(.text_plain);
            errdefer child.deinit();
            try child.setPayload([]const u8, "text");
            try child.seal();

            child = try node.append(.text_italic);
            try child.setPayload([]const u8, "italic");
            try child.seal();

            child = try node.append(.text_bold);
            try child.setPayload([]const u8, "bold");
            try child.seal();

            child = try node.append(.text_bold_italic);
            try child.setPayload([]const u8, "bold italic");
            try child.seal();

            child = try node.append(.text_code);
            try child.setPayload([]const u8, "code");
            try child.seal();

            child = try node.append(.text_link);
            try child.setPayload([]const u8, "#");
            var link_text = try child.append(.text_plain);
            errdefer link_text.deinit();
            try link_text.setPayload([]const u8, "link");
            try link_text.seal();
            try child.seal();

            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue("text _italic_ **bold** ***bold italic*** `code` [link](#)", doc);
}

test "Document: Heading" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_heading);
            errdefer node.deinit();
            try node.setPayload(MarkHeading, .{
                .level = 2,
                .text = "Foo",
            });
            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue("## Foo", doc);
}

test "Document: Quote" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_quote);
            errdefer node.deinit();

            var child = try node.append(.text_plain);
            errdefer child.deinit();
            try child.setPayload([]const u8, "foo");
            try child.seal();

            try node.seal();

            node = try tree.append(.block_quote);

            var para = try node.append(.block_paragraph);
            errdefer para.deinit();
            child = try para.append(.text_plain);
            try child.setPayload([]const u8, "bar");
            try child.seal();
            try para.seal();

            para = try node.append(.block_paragraph);
            child = try para.append(.text_plain);
            try child.setPayload([]const u8, "baz");
            try child.seal();
            try para.seal();

            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\> foo
        \\
        \\> bar
        \\>
        \\> baz
    , doc);
}

test "Document: Code" {
    const code = zig.Container{ .statements = &.{} };
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_code);
            errdefer node.deinit();
            try node.setPayload(usize, @intFromPtr(&code));

            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\```zig
        \\
        \\```
    , doc);
}

test "Document: List" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_list);
            errdefer node.deinit();
            try node.setPayload(ListKind, .unordered);

            var item = try node.append(.block_list_item);
            errdefer item.deinit();
            var child = try item.append(.text_plain);
            errdefer child.deinit();
            try child.setPayload([]const u8, "foo");
            try child.seal();
            try item.seal();

            item = try node.append(.block_list_item);

            var para = try item.append(.block_paragraph);
            errdefer para.deinit();
            child = try para.append(.text_plain);
            try child.setPayload([]const u8, "bar");
            try child.seal();
            try para.seal();

            para = try item.append(.block_paragraph);
            child = try para.append(.text_plain);
            try child.setPayload([]const u8, "baz");
            try child.seal();
            try para.seal();

            try item.seal();

            item = try node.append(.block_list_item);
            child = try item.append(.text_plain);
            try child.setPayload([]const u8, "qux");
            try child.seal();
            try item.seal();

            try node.seal();

            node = try tree.append(.block_list);
            try node.setPayload(ListKind, .ordered);

            item = try node.append(.block_list_item);
            child = try item.append(.text_plain);
            try child.setPayload([]const u8, "foo");
            try child.seal();
            try item.seal();

            item = try node.append(.block_list_item);
            child = try item.append(.text_plain);
            try child.setPayload([]const u8, "bar");
            try child.seal();
            try item.seal();

            var sublist = try node.append(.block_list);
            try sublist.setPayload(ListKind, .ordered);

            item = try sublist.append(.block_list_item);
            child = try item.append(.text_plain);
            try child.setPayload([]const u8, "baz");
            try child.seal();
            try item.seal();

            item = try sublist.append(.block_list_item);
            child = try item.append(.text_plain);
            try child.setPayload([]const u8, "qux");
            try child.seal();
            try item.seal();

            try sublist.seal();
            try node.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\- foo
        \\- bar
        \\
        \\    baz
        \\- qux
        \\
        \\1. foo
        \\2. bar
        \\    1. baz
        \\    2. qux
    , doc);
}

test "Document: Table" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var table = try tree.append(.block_table);
            errdefer table.deinit();
            try table.setPayload(u8, 3);

            var cell = try table.append(.block_table_column);
            errdefer cell.deinit();
            try cell.setPayload(MarkColumn, .{
                .aligns = .right,
                .self_width = 1,
                .dynamic_width = 8,
            });
            var child = try cell.append(.text_plain);
            errdefer child.deinit();
            try child.setPayload([]const u8, "A");
            try child.seal();
            try cell.seal();

            cell = try table.append(.block_table_column);
            try cell.setPayload(MarkColumn, .{
                .aligns = .center,
                .self_width = 1,
                .dynamic_width = 11,
            });
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "B");
            try child.seal();
            try cell.seal();

            cell = try table.append(.block_table_column);
            try cell.setPayload(MarkColumn, .{
                .aligns = .left,
                .self_width = 1,
                .dynamic_width = 7,
            });
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "C");
            try child.seal();
            try cell.seal();

            var row = try table.append(.block_table_row);
            errdefer row.deinit();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 8);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "A01 Foo!");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 3);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "B01");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 3);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "C01");
            try child.seal();
            try cell.seal();

            try row.seal();
            row = try table.append(.block_table_row);

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 3);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "A02");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 11);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "B02 Bar Baz");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 3);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "C02");
            try child.seal();
            try cell.seal();

            try row.seal();
            row = try table.append(.block_table_row);

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 3);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "A03");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 3);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "B03");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            try cell.setPayload(u8, 7);
            child = try cell.append(.text_plain);
            try child.setPayload([]const u8, "C03 Qux");
            try child.seal();
            try cell.seal();

            try row.seal();
            try table.seal();
        }

        break :blk Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\| A        | B           | C       |
        \\|---------:|:-----------:|:--------|
        \\| A01 Foo! | B01         | C01     |
        \\| A02      | B02 Bar Baz | C02     |
        \\| A03      | B03         | C03 Qux |
    , doc);
}

pub const DocumentAuthor = struct {
    tree: MarkTreeAuthor,

    pub fn init(allocator: Allocator) !DocumentAuthor {
        return .{ .tree = try MarkTreeAuthor.init(allocator) };
    }

    pub fn deinit(self: *DocumentAuthor) void {
        self.tree.deinit();
    }

    pub fn consume(self: *DocumentAuthor) !Document {
        return Document{ .tree = try self.tree.consume() };
    }

    pub fn raw(self: *DocumentAuthor, value: []const u8) !void {
        var node = try self.tree.append(.block_raw);
        errdefer node.deinit();
        try node.setPayload([]const u8, value);
        try node.seal();
    }

    pub fn rawFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.tree.append(.block_raw);
        errdefer node.deinit();
        _ = try node.setPayloadFmt(format, args);
        try node.seal();
    }

    pub fn comment(self: *DocumentAuthor, text: []const u8) !void {
        var node = try self.tree.append(.block_comment);
        errdefer node.deinit();
        try node.setPayload([]const u8, text);
        try node.seal();
    }

    pub fn commentFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.tree.append(.block_comment);
        errdefer node.deinit();
        _ = try node.setPayloadFmt(format, args);
        try node.seal();
    }

    pub fn heading(self: *DocumentAuthor, level: u8, text: []const u8) !void {
        if (level == 0 or level > 6) return error.InvalidHeadingLevel;
        var node = try self.tree.append(.block_heading);
        errdefer node.deinit();
        try node.setPayload(MarkHeading, .{
            .level = level,
            .text = text,
        });
        try node.seal();
    }

    pub fn headingFmt(self: *DocumentAuthor, level: u8, comptime format: []const u8, args: anytype) !void {
        if (level == 0 or level > 6) return error.InvalidHeadingLevel;
        var node = try self.tree.append(.block_heading);
        errdefer node.deinit();

        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, format, args);

        try node.setPayload(MarkHeading, .{
            .level = level,
            .text = text,
        });
        try node.seal();
    }

    pub fn paragraph(self: *DocumentAuthor, text: []const u8) !void {
        var node = try self.tree.append(.block_paragraph);
        try StyledAuthor.createPlain(&node, text);
    }

    pub fn paragraphFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.tree.append(.block_paragraph);
        _ = try StyledAuthor.createPlainFmt(&node, format, args);
    }

    pub fn paragraphStyled(self: *DocumentAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.tree.append(.block_paragraph) };
    }

    pub fn quote(self: *DocumentAuthor, text: []const u8) !void {
        var node = try self.tree.append(.block_quote);
        try StyledAuthor.createPlain(&node, text);
    }

    pub fn quoteFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.tree.append(.block_quote);
        _ = try StyledAuthor.createPlainFmt(&node, format, args);
    }

    pub fn quoteStyled(self: *DocumentAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.tree.append(.block_quote) };
    }

    pub fn quoteContainer(self: *DocumentAuthor) !ContainerAuthor {
        return ContainerAuthor{ .parent = try self.tree.append(.block_quote) };
    }

    pub fn list(self: *DocumentAuthor, kind: ListKind) !ListAuthor {
        const node = try self.tree.append(.block_list);
        return ListAuthor{ .parent = node, .kind = kind };
    }

    pub fn table(self: *DocumentAuthor) !TableAuthor {
        return TableAuthor{ .parent = try self.tree.append(.block_table) };
    }

    pub fn code(self: *DocumentAuthor, closure: zig.ContainerClosure) !void {
        try self.codeWith({}, closure);
    }

    pub fn codeWith(
        self: *DocumentAuthor,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), zig.ContainerClosure),
    ) !void {
        const alloc = self.tree.allocator;
        const data = try alloc.create(zig.Container);
        errdefer alloc.destroy(data);
        data.* = try zig.Container.init(alloc, ctx, closure);
        errdefer data.deinit(alloc);

        var node = try self.tree.append(.block_code);
        errdefer node.deinit();
        try node.setPayload(usize, @intFromPtr(data));
        try node.seal();
    }
};

pub const ContainerAuthor = struct {
    parent: MarkTreeAuthor.Node,

    pub fn deinit(self: *ContainerAuthor) void {
        self.parent.deinit();
    }

    pub fn seal(self: *ContainerAuthor) !void {
        try self.parent.seal();
    }

    pub fn paragraph(self: *ContainerAuthor, text: []const u8) !void {
        var node = try self.parent.append(.block_paragraph);
        try StyledAuthor.createPlain(&node, text);
    }

    pub fn paragraphFmt(self: *ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.block_paragraph);
        _ = try StyledAuthor.createPlainFmt(&node, format, args);
    }

    pub fn paragraphStyled(self: *ContainerAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.parent.append(.block_paragraph) };
    }

    pub fn quote(self: *ContainerAuthor, text: []const u8) !void {
        var node = try self.parent.append(.block_quote);
        try StyledAuthor.createPlain(&node, text);
    }

    pub fn quoteFmt(self: *ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.block_quote);
        _ = try StyledAuthor.createPlainFmt(&node, format, args);
    }

    pub fn quoteStyled(self: *ContainerAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.parent.append(.block_quote) };
    }

    pub fn quoteContainer(self: *ContainerAuthor) !ContainerAuthor {
        return ContainerAuthor{ .parent = try self.parent.append(.block_quote) };
    }

    pub fn list(self: *ContainerAuthor, kind: ListKind) !ListAuthor {
        const node = try self.parent.append(.block_list);
        return ListAuthor{ .parent = node, .kind = kind };
    }

    pub fn table(self: *ContainerAuthor) !TableAuthor {
        return TableAuthor{ .node = try self.tree.append(.block_table) };
    }

    pub fn code(self: *ContainerAuthor, closure: zig.ContainerClosure) !void {
        try self.codeWith({}, closure);
    }

    pub fn codeWith(
        self: *ContainerAuthor,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), zig.ContainerClosure),
    ) !void {
        const alloc = self.parent.allocator;
        const data = try alloc.create(zig.Container);
        errdefer alloc.destroy(data);
        data.* = try zig.Container.init(alloc, ctx, closure);
        errdefer data.deinit(alloc);

        var node = try self.parent.append(.block_code);
        errdefer node.deinit();
        try node.setPayload(usize, @intFromPtr(data));
        try node.seal();
    }
};

pub const StyledAuthor = struct {
    parent: MarkTreeAuthor.Node,
    callback: ?Callback = null,

    const CallbackFn = *const fn (
        ctx: *anyopaque,
        node: *MarkTreeAuthor.Node,
        index: usize,
        length: usize,
    ) anyerror!void;

    const Callback = struct {
        index: usize,
        context: *anyopaque,
        func: CallbackFn,
        length: usize = 0,

        pub fn increment(self: *Callback, length: usize) void {
            self.length += if (self.length == 0) length else length + 1;
        }
    };

    fn createPlain(parent: *MarkTreeAuthor.Node, text: []const u8) !void {
        errdefer parent.deinit();
        var child = try parent.append(.text_plain);
        errdefer child.deinit();
        try child.setPayload([]const u8, text);
        try child.seal();
        try parent.seal();
    }

    fn createPlainFmt(parent: *MarkTreeAuthor.Node, comptime format: []const u8, args: anytype) !usize {
        errdefer parent.deinit();
        var child = try parent.append(.text_plain);
        errdefer child.deinit();
        const length = try child.setPayloadFmt(format, args);
        try child.seal();
        try parent.seal();
        return length;
    }

    pub fn deinit(self: *StyledAuthor) void {
        self.parent.deinit();
    }

    pub fn seal(self: *StyledAuthor) !void {
        if (self.callback) |cb| try cb.func(cb.context, &self.parent, cb.index, cb.length);
        try self.parent.seal();
    }

    pub fn plain(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_plain);
        errdefer node.deinit();
        try node.setPayload([]const u8, text);
        try node.seal();

        if (self.callback) |*cb| cb.increment(text.len);
    }

    pub fn plainFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_plain);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |*cb| cb.increment(len);
    }

    pub fn italic(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_italic);
        errdefer node.deinit();
        try node.setPayload([]const u8, text);
        try node.seal();

        if (self.callback) |*cb| cb.increment(2 + text.len);
    }

    pub fn italicFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_italic);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |*cb| cb.increment(2 + len);
    }

    pub fn bold(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_bold);
        errdefer node.deinit();
        try node.setPayload([]const u8, text);
        try node.seal();

        if (self.callback) |*cb| cb.increment(4 + text.len);
    }

    pub fn boldFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_bold);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |*cb| cb.increment(4 + len);
    }

    pub fn boldItalic(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_bold_italic);
        errdefer node.deinit();
        try node.setPayload([]const u8, text);
        try node.seal();

        if (self.callback) |*cb| cb.increment(6 + text.len);
    }

    pub fn boldItalicFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_bold_italic);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |*cb| cb.increment(6 + len);
    }

    pub fn code(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_code);
        errdefer node.deinit();
        try node.setPayload([]const u8, text);
        try node.seal();

        if (self.callback) |*cb| cb.increment(2 + text.len);
    }

    pub fn codeFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_code);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |*cb| cb.increment(2 + len);
    }

    pub fn link(self: *StyledAuthor, href: []const u8, text: []const u8) !void {
        var node = try self.parent.append(.text_link);
        try node.setPayload([]const u8, href);
        try StyledAuthor.createPlain(&node, text);

        if (self.callback) |*cb| cb.increment(4 + href.len + text.len);
    }

    pub fn linkFmt(self: *StyledAuthor, href: []const u8, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_link);
        try node.setPayload([]const u8, href);
        const len = try StyledAuthor.createPlainFmt(&node, format, args);

        if (self.callback) |*cb| cb.increment(4 + href.len + len);
    }

    pub fn linkStyled(self: *StyledAuthor, href: []const u8) !StyledAuthor {
        var node = try self.parent.append(.text_link);
        try node.setPayload([]const u8, href);

        if (self.callback) |*cb| {
            cb.increment(4 + href.len);
            return StyledAuthor{
                .parent = node,
                .callback = Callback{
                    .index = 0,
                    .context = self,
                    .func = increment,
                },
            };
        } else {
            return StyledAuthor{ .parent = node };
        }
    }

    fn increment(ctx: *anyopaque, _: *MarkTreeAuthor.Node, _: usize, length: usize) !void {
        const self: *StyledAuthor = @ptrCast(@alignCast(ctx));
        self.callback.?.increment(length);
    }
};

pub const ListAuthor = struct {
    kind: ListKind,
    parent: MarkTreeAuthor.Node,

    pub fn deinit(self: *ListAuthor) void {
        self.parent.deinit();
    }

    pub fn seal(self: *ListAuthor) !void {
        if (self.parent.children.items.len == 0) return error.EmptyList;
        try self.parent.setPayload(ListKind, self.kind);
        try self.parent.seal();
    }

    pub fn text(self: *ListAuthor, value: []const u8) !void {
        var child = try self.parent.append(.block_list_item);
        try StyledAuthor.createPlain(&child, value);
    }

    pub fn textFmt(self: *ListAuthor, comptime format: []const u8, args: anytype) !void {
        var child = try self.parent.append(.block_list_item);
        _ = try StyledAuthor.createPlainFmt(&child, format, args);
    }

    pub fn textStyled(self: *ListAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.parent.append(.block_list_item) };
    }

    pub fn container(self: *ListAuthor) !ContainerAuthor {
        const child = try self.parent.append(.block_list_item);
        return ContainerAuthor{ .parent = child };
    }

    pub fn list(self: *ListAuthor, kind: ListKind) !ListAuthor {
        const child = try self.parent.append(.block_list);
        return ListAuthor{ .parent = child, .kind = kind };
    }
};

pub const TableAuthor = struct {
    parent: MarkTreeAuthor.Node,
    columns_sealed: bool = false,
    columns: std.ArrayListUnmanaged(MarkColumn) = .{},

    pub fn deinit(self: *TableAuthor) void {
        self.columns.deinit(self.parent.allocator);
        self.parent.deinit();
    }

    pub fn seal(self: *TableAuthor) !void {
        const col_len = self.columns.items.len;
        if (col_len == 0) return error.EmptyTable;
        if (col_len > MAX_TABLE_COLUMNS) return error.TooManyTableColumns;
        if (self.parent.children.items.len == col_len) return error.EmptyTable;

        for (self.columns.items, 0..) |col, i| {
            const child = self.parent.children.items[i];
            self.parent.tree.TEMP_overridePayload(child, mem.asBytes(&col));
        }

        try self.parent.setPayload(u8, @truncate(col_len));
        try self.parent.seal();

        self.columns.deinit(self.parent.allocator);
    }

    pub fn column(self: *TableAuthor, aligns: ColumnAlign, value: []const u8) !void {
        if (value.len > 255) return error.CellValueTooLong;
        if (self.columns_sealed) return error.TableColumnAfterRows;

        try self.columns.append(self.parent.allocator, MarkColumn{
            .aligns = aligns,
            .self_width = @truncate(value.len),
            .dynamic_width = @truncate(value.len),
        });
        errdefer _ = self.columns.pop();

        var child = try self.parent.append(.block_table_column);
        try child.setPayload(MarkColumn, .{});
        try StyledAuthor.createPlain(&child, value);
    }

    pub fn columnFmt(
        self: *TableAuthor,
        aligns: ColumnAlign,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (self.columns_sealed) return error.TableColumnAfterRows;

        var child = try self.parent.append(.block_table_column);
        try child.setPayload(MarkColumn, .{});
        errdefer child.deinit();

        const len = try StyledAuthor.createPlainFmt(&child, format, args);
        if (len > 255) return error.CellValueTooLong;

        try self.columns.append(self.parent.allocator, MarkColumn{
            .aligns = aligns,
            .self_width = @truncate(len),
            .dynamic_width = @truncate(len),
        });
    }

    pub fn columnStyled(self: *TableAuthor, aligns: ColumnAlign) !StyledAuthor {
        if (self.columns_sealed) return error.TableColumnAfterRows;

        const column_index = self.columns.items.len;
        try self.columns.append(self.parent.allocator, MarkColumn{ .aligns = aligns });
        errdefer _ = self.columns.pop();

        return StyledAuthor{
            .parent = try self.parent.append(.block_table_column),
            .callback = .{
                .context = &self.columns,
                .index = column_index,
                .func = setStyledColumnWidth,
            },
        };
    }

    fn setStyledColumnWidth(ctx: *anyopaque, node: *MarkTreeAuthor.Node, index: usize, width: usize) !void {
        if (width > 255) return error.CellValueTooLong;
        try node.setPayload(MarkColumn, .{});
        const self: *std.ArrayListUnmanaged(MarkColumn) = @ptrCast(@alignCast(ctx));
        const col = &self.items[index];
        col.self_width = @truncate(width);
        col.dynamic_width = @truncate(width);
    }

    pub fn rowText(self: *TableAuthor, cells: []const []const u8) !void {
        if (cells.len != self.columns.items.len) return error.RowColumnsMismatch;

        var tbl_row = try self.parent.append(.block_table_row);
        errdefer tbl_row.deinit();

        for (cells, 0..) |cell, i| {
            if (cell.len > 255) return error.CellValueTooLong;

            var child = try tbl_row.append(.block_table_cell);
            errdefer child.deinit();
            try child.setPayload(u8, @truncate(cell.len));
            try StyledAuthor.createPlain(&child, cell);
            const col = &self.columns.items[i];
            if (cell.len > col.dynamic_width) col.dynamic_width = @truncate(cell.len);
        }

        try tbl_row.seal();
        self.columns_sealed = true;
    }

    pub fn row(self: *TableAuthor) !Row {
        const child = try self.parent.append(.block_table_row);
        self.columns_sealed = true;
        return Row{
            .parent = child,
            .columns = &self.columns,
        };
    }

    pub const Row = struct {
        parent: MarkTreeAuthor.Node,
        columns: *std.ArrayListUnmanaged(MarkColumn),

        pub fn deinit(self: *Row) void {
            self.parent.deinit();
        }

        pub fn seal(self: *Row) !void {
            try self.parent.seal();
        }

        pub fn cell(self: *Row, value: []const u8) !void {
            const col_index = self.parent.children.items.len;
            if (col_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const col = &self.columns.items[col_index];
            var child = try self.parent.append(.block_table_cell);
            try child.setPayload(u8, @truncate(value.len));
            try StyledAuthor.createPlain(&child, value);
            if (value.len > col.dynamic_width) col.dynamic_width = @truncate(value.len);
        }

        pub fn cellFmt(self: *Row, comptime format: []const u8, args: anytype) !void {
            const col_index = self.parent.children.items.len;
            if (col_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const col = &self.columns.items[col_index];
            var child = try self.parent.append(.block_table_cell);
            errdefer child.deinit();

            var text = try child.append(.text_plain);
            errdefer text.deinit();
            const width = try text.setPayloadFmt(format, args);
            if (width > col.dynamic_width) col.dynamic_width = @truncate(width);
            try text.seal();

            try child.setPayload(u8, @truncate(width));
            try child.seal();
        }

        pub fn cellStyled(self: *Row) !StyledAuthor {
            const column_index = self.parent.children.items.len;
            if (column_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const child = try self.parent.append(.block_table_cell);
            return StyledAuthor{
                .parent = child,
                .callback = .{
                    .context = self,
                    .index = column_index,
                    .func = updateStyledCellWidth,
                },
            };
        }

        fn updateStyledCellWidth(ctx: *anyopaque, node: *MarkTreeAuthor.Node, index: usize, width: usize) !void {
            if (width > 255) return error.CellValueTooLong;
            const self: *Row = @ptrCast(@alignCast(ctx));
            try node.setPayload(u8, @truncate(width));

            const col = &self.columns.items[index];
            if (width > col.dynamic_width) col.dynamic_width = @truncate(width);
        }
    };
};

test "DocumentAuthor: Raw" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        try md.raw("foo");
        try md.rawFmt("bar {d}", .{108});

        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\foo
        \\
        \\bar 108
    , doc);
}

test "DocumentAuthor: Comment" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        try md.comment("foo");
        try md.commentFmt("bar {d}", .{108});

        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\<!-- foo -->
        \\
        \\<!-- bar 108 -->
    , doc);
}

test "DocumentAuthor: Paragraph & Text" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        try md.paragraph("foo");
        try md.paragraphFmt("bar{d}", .{108});

        var style = try md.paragraphStyled();
        errdefer style.deinit();
        try style.plain("text");
        try style.plainFmt("text{d}", .{108});
        try style.italic("italic");
        try style.italicFmt("italic {d}", .{108});
        try style.bold("bold");
        try style.boldFmt("bold {d}", .{108});
        try style.boldItalic("bold italic");
        try style.boldItalicFmt("bold italic {d}", .{108});
        try style.code("code");
        try style.codeFmt("code {d}", .{108});
        try style.link("#", "link");
        try style.linkFmt("#", "link {d}", .{108});

        var link = try style.linkStyled("#");
        errdefer link.deinit();
        try link.plain("link style");
        try link.seal();

        try style.seal();
        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\foo
        \\
        \\bar108
        \\
        \\text text108 _italic_ _italic 108_ **bold** **bold 108** ***bold italic***
    ++ " ***bold italic 108*** `code` `code 108` [link](#) [link 108](#) [link style](#)", doc);
}

test "DocumentAuthor: Heading" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        try md.heading(2, "Foo");
        try md.headingFmt(2, "Bar {d}", .{108});

        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\## Foo
        \\
        \\## Bar 108
    , doc);
}

test "DocumentAuthor: Quote" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        try md.quote("foo");
        try md.quoteFmt("bar {d}", .{108});

        {
            var style = try md.quoteStyled();
            errdefer style.deinit();
            try style.plain("baz style");
            try style.seal();
        }

        {
            var container = try md.quoteContainer();
            errdefer container.deinit();
            try container.paragraph("qux 0");
            try container.paragraph("qux 1");
            try container.seal();
        }

        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\> foo
        \\
        \\> bar 108
        \\
        \\> baz style
        \\
        \\> qux 0
        \\>
        \\> qux 1
    , doc);
}

test "DocumentAuthor: Code" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const doc = blk: {
        var md = try DocumentAuthor.init(arena_alloc);
        errdefer md.deinit();

        try md.code(struct {
            fn f(_: *zig.ContainerBuild) !void {}
        }.f);

        break :blk try md.consume();
    };
    defer doc.deinit(arena_alloc);
    try Writer.expectValue(
        \\```zig
        \\
        \\```
    , doc);
}

test "DocumentAuthor: List" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        {
            var list = try md.list(.unordered);
            errdefer list.deinit();

            try list.text("foo");
            try list.textFmt("bar {d}", .{108});

            {
                var style = try list.textStyled();
                errdefer style.deinit();
                try style.plain("baz style");
                try style.seal();
            }

            {
                var sublist = try list.list(.ordered);
                errdefer sublist.deinit();
                try sublist.text("first");
                try sublist.text("second");
                try sublist.seal();
            }

            {
                var container = try list.container();
                errdefer container.deinit();
                try container.paragraph("qux");
                try container.paragraph("paragraph");
                try container.seal();
            }

            try list.seal();
        }

        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\- foo
        \\- bar 108
        \\- baz style
        \\    1. first
        \\    2. second
        \\- qux
        \\
        \\    paragraph
    , doc);
}

test "DocumentAuthor: Table" {
    const doc = blk: {
        var md = try DocumentAuthor.init(test_alloc);
        errdefer md.deinit();

        {
            var table = try md.table();
            errdefer table.deinit();

            try table.column(.right, "A");
            try table.columnFmt(.center, "B {d}", .{108});
            {
                var col = try table.columnStyled(.left);
                errdefer col.deinit();
                try col.plain("C Style");
                try col.seal();
            }

            try table.rowText(&.{ "foo", "bar", "baz" });
            {
                var row = try table.row();
                errdefer row.deinit();

                try row.cell("foo");
                try row.cellFmt("bar {d}", .{108});
                {
                    var cell = try row.cellStyled();
                    errdefer cell.deinit();
                    try cell.plain("baz");
                    try cell.seal();
                }

                try row.seal();
            }

            try table.seal();
        }

        break :blk try md.consume();
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\| A   | B 108   | C Style |
        \\|----:|:-------:|:--------|
        \\| foo | bar     | baz     |
        \\| foo | bar 108 | baz     |
    , doc);
}

test {
    _ = html;
}
