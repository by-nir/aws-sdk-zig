const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const dcl = @import("utils/declarative.zig");
const Cb = dcl.Callback;
const Closure = dcl.Closure;
const StackChain = dcl.StackChain;
const InferCallback = dcl.InferCallback;
const callClosure = dcl.callClosure;
const createCallback = dcl.callback;
const zig = @import("zig.zig");
const Writer = @import("CodegenWriter.zig");
const srct = @import("utils/tree.zig");

pub const html = @import("md/html.zig");

pub const ListKind = enum(u8) { unordered, ordered };
pub const ColumnAlign = enum(u8) { left, center, right };

const TreeViewer = srct.SourceViewer(Mark);
const MutableTree = srct.MutableSourceTree(Mark);

pub const DocumentClosure = *const fn (ContainerAuthor) anyerror!void;

// TODO: Support soft/hard width guidelines

pub fn authorDocument(allocator: Allocator, ctx: anytype, closure: Closure(@TypeOf(ctx), DocumentClosure)) !Document {
    var author = try MutableDocument.init(allocator);
    errdefer author.deinit();

    try callClosure(ctx, closure, .{author.root()});
    return author.toReadOnly(allocator);
}

const INDENT = " " ** 4;
const MAX_TABLE_COLUMNS = 16;

const MarkColumn = packed struct(u24) {
    aligns: ColumnAlign = .left,
    self_width: u8 = 0,
    dynamic_width: u8 = 0,
};

const MarkLink = struct {
    href: []const u8,
    title: []const u8 = "",
};

const Mark = enum {
    document,
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
    inline_plain,
    inline_italic,
    inline_bold,
    inline_bold_italic,
    inline_code,
    inline_link,

    pub fn is_inline(self: Mark) bool {
        return @intFromEnum(self) >= @intFromEnum(Mark.inline_plain);
    }
};

pub const Document = struct {
    tree: srct.SourceTree(Mark),

    pub fn deinit(self: Document, allocator: Allocator) void {
        self.tree.deinit(allocator);
    }

    pub fn write(self: Document, writer: *Writer) !void {
        var first = true;
        const tree = self.tree.view();
        var it = tree.iterateChildren(srct.ROOT);
        while (it.next()) |node| : (first = false) {
            if (!first) try writeNodeLineBreak(writer);
            try writeNode(writer, tree, node);
        }
    }

    fn writeNode(writer: *Writer, tree: TreeViewer, node: srct.NodeHandle) anyerror!void {
        switch (tree.tag(node)) {
            .block_raw, .inline_plain => try writer.appendString(tree.payload(node, []const u8)),
            .inline_italic => try writeInlineNode(writer, tree, "_", node),
            .inline_bold => try writeInlineNode(writer, tree, "**", node),
            .inline_bold_italic => try writeInlineNode(writer, tree, "***", node),
            .inline_code => try writeInlineNode(writer, tree, "`", node),
            .inline_link => {
                const payload = tree.payload(node, MarkLink);
                try writer.appendChar('[');
                try writeNodeChildren(writer, tree, node, .inlined);
                try writer.appendString("](");
                if (payload.title.len > 0) {
                    try writer.appendFmt("{s} \"{s}\"", .{ payload.href, payload.title });
                } else {
                    try writer.appendString(payload.href);
                }
                try writer.appendChar(')');
            },
            .block_comment => try writer.appendFmt("<!-- {s} -->", .{tree.payload(node, []const u8)}),
            .block_paragraph => try writeNodeChildren(writer, tree, node, .inlined),
            .block_heading => {
                const level = tree.payload(node, u8);
                std.debug.assert(level > 0 and level <= 6);

                const prefix = "#######"[6 - level .. 6];
                try writer.appendFmt("{s} ", .{prefix});
                try writeNodeChildren(writer, tree, node, .inlined);
            },
            .block_quote => {
                try writer.pushIndent("> ");
                defer writer.popIndent();
                try writer.appendString("> ");
                try writeNodeChildren(writer, tree, node, .inlined);
            },
            .block_code => {
                const code: *const zig.Container = @ptrFromInt(tree.payload(node, usize));

                try writer.appendString("```zig\n");
                try code.write(writer);
                try writer.breakString("```");
            },
            .block_list => {
                var items = tree.iterateChildren(node);
                std.debug.assert(items.length() > 0);

                var i: usize = 1;
                while (items.next()) |item| {
                    if (i > 1) try writer.breakString("");
                    if (tree.tag(item) == .block_list) {
                        try writer.pushIndent(INDENT);
                        defer writer.popIndent();
                        try writer.appendString(INDENT);
                        try writeNode(writer, tree, item);
                    } else {
                        switch (tree.payload(node, ListKind)) {
                            .unordered => try writer.appendString("- "),
                            .ordered => try writer.appendFmt("{d}. ", .{i}),
                        }
                        try writeNodeChildren(writer, tree, item, .inlined_or_indent);
                        i += 1;
                    }
                }
            },
            .block_table => {
                const col_len = tree.payload(node, u8);

                const whitespace = " " ** 255;
                const separator = "-" ** 255;

                var widths: [MAX_TABLE_COLUMNS]u8 = undefined;

                // Header
                try writer.appendChar('|');
                for (0..col_len) |i| {
                    const col_node = tree.childAt(node, i);
                    const column = tree.payload(col_node, MarkColumn);
                    widths[i] = column.dynamic_width;
                    const padding = column.dynamic_width - column.self_width;

                    try writer.appendChar(' ');
                    try writeNodeChildren(writer, tree, col_node, .inlined);
                    try writer.appendString(whitespace[0..padding]);
                    try writer.appendString(" |");
                }

                // Separator
                try writer.breakChar('|');
                for (0..col_len) |i| {
                    const item = tree.childAt(node, i);
                    const column = tree.payload(item, MarkColumn);
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
                var it = tree.iterateChildren(node);
                it.skip(col_len);
                while (it.next()) |row_node| {
                    try writer.breakChar('|');

                    var i: usize = 0;
                    var row = tree.iterateChildren(row_node);
                    while (row.next()) |cell_node| : (i += 1) {
                        const padding = widths[i] - tree.payload(cell_node, u8);

                        try writer.appendChar(' ');
                        try writeNodeChildren(writer, tree, cell_node, .inlined);
                        try writer.appendString(whitespace[0..padding]);
                        try writer.appendString(" |");
                    }
                }
            },
            else => return error.UnexpectedNodeTag,
        }
    }

    const Concat = enum { blocks, inlined, inlined_or_indent };
    fn writeNodeChildren(writer: *Writer, tree: TreeViewer, parent: srct.NodeHandle, concat: Concat) !void {
        var inlined = false;
        var defer_pop_indent = false;

        var it = tree.iterateChildren(parent);
        if (it.next()) |node| {
            try writeNode(writer, tree, node);

            const tag = tree.tag(node);
            switch (concat) {
                .blocks => try writer.breakEmpty(1),
                .inlined => inlined = tag.is_inline(),
                .inlined_or_indent => {
                    if (tag.is_inline()) {
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
            try writeNodeInlineSpace(writer, tree, it.peek());
            while (it.next()) |node| {
                try writeNode(writer, tree, node);
                try writeNodeInlineSpace(writer, tree, it.peek());
            }
        } else {
            while (it.next()) |node| {
                try writeNodeLineBreak(writer);
                try writeNode(writer, tree, node);
            }
        }
    }

    fn writeNodeLineBreak(writer: *Writer) !void {
        try writer.breakEmpty(1);
        try writer.breakString("");
    }

    fn writeInlineNode(writer: *Writer, tree: TreeViewer, comptime mark: []const u8, node: srct.NodeHandle) !void {
        try writer.appendString(mark);
        if (tree.countChildren(node) > 0) {
            try writeNodeChildren(writer, tree, node, .inlined);
        } else {
            try writer.appendString(tree.payload(node, []const u8));
        }
        try writer.appendString(mark);
    }

    fn writeNodeInlineSpace(writer: *Writer, tree: TreeViewer, next: ?srct.NodeHandle) !void {
        var node = next orelse return;
        while (tree.countChildren(node) > 0) node = tree.childAt(node, 0);
        const start_text = tree.payload(node, []const u8);

        if (mem.indexOfScalar(u8, ".,;:?!", start_text[0]) != null) return;
        try writer.appendChar(' ');
    }
};

test "MarkdownDocument: Raw" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        _ = try tree.appendNodePayload(srct.ROOT, .block_raw, []const u8, "foo");
        _ = try tree.appendNodePayload(srct.ROOT, .block_raw, []const u8, "bar");

        break :blk Document{
            .tree = try tree.toReadOnly(test_alloc),
        };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\foo
        \\
        \\bar
    , doc);
}

test "MarkdownDocument: Comment" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        _ = try tree.appendNodePayload(srct.ROOT, .block_comment, []const u8, "foo");

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue("<!-- foo -->", doc);
}

test "MarkdownDocument: Paragraph & Text" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        const node = try tree.appendNode(srct.ROOT, .block_paragraph);

        _ = try tree.appendNodePayload(node, .inline_plain, []const u8, "text");
        _ = try tree.appendNodePayload(node, .inline_italic, []const u8, "italic");
        _ = try tree.appendNodePayload(node, .inline_bold, []const u8, "bold");
        _ = try tree.appendNodePayload(node, .inline_bold_italic, []const u8, "bold italic");
        _ = try tree.appendNodePayload(node, .inline_code, []const u8, "code");

        const child = try tree.appendNodePayload(node, .inline_link, MarkLink, .{ .href = "#" });
        _ = try tree.appendNodePayload(child, .inline_plain, []const u8, "link");

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue("text _italic_ **bold** ***bold italic*** `code` [link](#)", doc);
}

test "MarkdownDocument: Heading" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        const node = try tree.appendNodePayload(srct.ROOT, .block_heading, u8, 2);
        _ = try tree.appendNodePayload(node, .inline_plain, []const u8, "Foo");

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue("## Foo", doc);
}

test "MarkdownDocument: Quote" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        var node = try tree.appendNode(srct.ROOT, .block_quote);
        _ = try tree.appendNodePayload(node, .inline_plain, []const u8, "foo");

        node = try tree.appendNode(srct.ROOT, .block_quote);

        var para = try tree.appendNode(node, .block_paragraph);
        _ = try tree.appendNodePayload(para, .inline_plain, []const u8, "bar");

        para = try tree.appendNode(node, .block_paragraph);
        _ = try tree.appendNodePayload(para, .inline_plain, []const u8, "baz");

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
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

test "MarkdownDocument: Code" {
    const code = zig.Container{ .statements = &.{} };
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        _ = try tree.appendNodePayload(srct.ROOT, .block_code, usize, @intFromPtr(&code));

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\```zig
        \\
        \\```
    , doc);
}

test "MarkdownDocument: List" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        {
            const node = try tree.appendNodePayload(srct.ROOT, .block_list, ListKind, .unordered);

            var item = try tree.appendNode(node, .block_list_item);
            _ = try tree.appendNodePayload(item, .inline_plain, []const u8, "foo");

            item = try tree.appendNode(node, .block_list_item);

            var para = try tree.appendNode(item, .block_paragraph);
            _ = try tree.appendNodePayload(para, .inline_plain, []const u8, "bar");

            para = try tree.appendNode(item, .block_paragraph);
            _ = try tree.appendNodePayload(para, .inline_plain, []const u8, "baz");

            item = try tree.appendNode(node, .block_list_item);
            _ = try tree.appendNodePayload(item, .inline_plain, []const u8, "qux");
        }

        {
            const node = try tree.appendNodePayload(srct.ROOT, .block_list, ListKind, .ordered);

            var item = try tree.appendNode(node, .block_list_item);
            _ = try tree.appendNodePayload(item, .inline_plain, []const u8, "foo");

            item = try tree.appendNode(node, .block_list_item);
            _ = try tree.appendNodePayload(item, .inline_plain, []const u8, "bar");

            const sublist = try tree.appendNodePayload(node, .block_list, ListKind, .ordered);

            item = try tree.appendNode(sublist, .block_list_item);
            _ = try tree.appendNodePayload(item, .inline_plain, []const u8, "baz");

            item = try tree.appendNode(sublist, .block_list_item);
            _ = try tree.appendNodePayload(item, .inline_plain, []const u8, "qux");
        }

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
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

test "MarkdownDocument: Table" {
    const doc = blk: {
        var tree = try MutableTree.init(test_alloc, .document);
        errdefer tree.deinit();

        const table = try tree.appendNodePayload(srct.ROOT, .block_table, u8, 3);

        var cell = try tree.appendNodePayload(table, .block_table_column, MarkColumn, .{
            .aligns = .right,
            .self_width = 1,
            .dynamic_width = 8,
        });
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "A");

        cell = try tree.appendNodePayload(table, .block_table_column, MarkColumn, .{
            .aligns = .center,
            .self_width = 1,
            .dynamic_width = 11,
        });
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "B");

        cell = try tree.appendNodePayload(table, .block_table_column, MarkColumn, .{
            .aligns = .left,
            .self_width = 1,
            .dynamic_width = 7,
        });
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "C");

        var row = try tree.appendNode(table, .block_table_row);

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 8);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "A01 Foo!");

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 3);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "B01");

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 3);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "C01");

        row = try tree.appendNode(table, .block_table_row);

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 3);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "A02");

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 11);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "B02 Bar Baz");

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 3);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "C02");

        row = try tree.appendNode(table, .block_table_row);

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 3);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "A03");

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 3);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "B03");

        cell = try tree.appendNodePayload(row, .block_table_cell, u8, 7);
        _ = try tree.appendNodePayload(cell, .inline_plain, []const u8, "C03 Qux");

        break :blk Document{ .tree = try tree.toReadOnly(test_alloc) };
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

pub const MutableDocument = struct {
    tree: MutableTree,

    pub fn init(mut_alloc: Allocator) !MutableDocument {
        return .{ .tree = try MutableTree.init(mut_alloc, .document) };
    }

    pub fn deinit(self: *MutableDocument) void {
        self.tree.deinit();
    }

    /// The caller owns the returned memory. Clears the mutable document.
    pub fn toReadOnly(self: *MutableDocument, immut_alloc: Allocator) !Document {
        return .{ .tree = try self.tree.toReadOnly(immut_alloc) };
    }

    pub fn root(self: *MutableDocument) ContainerAuthor {
        return .{
            .tree = &self.tree,
            .parent = srct.ROOT,
        };
    }
};

pub const ContainerAuthor = struct {
    tree: *MutableTree,
    parent: srct.NodeHandle,

    pub fn deinit(self: ContainerAuthor) void {
        std.debug.assert(self.parent != srct.ROOT);
        self.tree.dropNode(self.parent);
    }

    pub fn raw(self: ContainerAuthor, value: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .block_raw, []const u8, value);
    }

    pub fn rawFmt(self: ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .block_raw);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.setPayloadFmt(node, format, args);
    }

    pub fn comment(self: ContainerAuthor, text: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .block_comment, []const u8, text);
    }

    pub fn commentFmt(self: ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .block_comment);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.setPayloadFmt(node, format, args);
    }

    pub fn heading(self: ContainerAuthor, level: u8, text: []const u8) !void {
        if (level == 0 or level > 6) return error.InvalidHeadingLevel;
        const node = try self.tree.appendNodePayload(self.parent, .block_heading, u8, level);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayload(node, .inline_plain, []const u8, text);
    }

    pub fn headingFmt(self: ContainerAuthor, level: u8, comptime format: []const u8, args: anytype) !void {
        if (level == 0 or level > 6) return error.InvalidHeadingLevel;
        const node = try self.tree.appendNodePayload(self.parent, .block_heading, u8, level);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayloadFmt(node, .inline_plain, format, args);
    }

    pub fn headingStyled(self: ContainerAuthor, level: u8) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNodePayload(self.parent, .block_heading, u8, level),
        };
    }

    pub fn paragraph(self: ContainerAuthor, text: []const u8) !void {
        const node = try self.tree.appendNode(self.parent, .block_paragraph);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayload(node, .inline_plain, []const u8, text);
    }

    pub fn paragraphFmt(self: ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .block_paragraph);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayloadFmt(node, .inline_plain, format, args);
    }

    pub fn paragraphStyled(self: ContainerAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_paragraph),
        };
    }

    pub fn quote(self: ContainerAuthor, text: []const u8) !void {
        const node = try self.tree.appendNode(self.parent, .block_quote);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayload(node, .inline_plain, []const u8, text);
    }

    pub fn quoteFmt(self: ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .block_quote);
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayloadFmt(node, .inline_plain, format, args);
    }

    pub fn quoteStyled(self: ContainerAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_quote),
        };
    }

    pub fn quoteContainer(self: ContainerAuthor) !ContainerAuthor {
        return ContainerAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_quote),
        };
    }

    pub fn list(self: ContainerAuthor, kind: ListKind) !ListAuthor {
        return ListAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNodePayload(self.parent, .block_list, ListKind, kind),
        };
    }

    pub fn table(self: ContainerAuthor) !TableAuthor {
        return TableAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_table),
        };
    }

    pub fn code(self: ContainerAuthor, closure: zig.ContainerClosure) !void {
        try self.codeWith({}, closure);
    }

    pub fn codeWith(
        self: ContainerAuthor,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), zig.ContainerClosure),
    ) !void {
        const alloc = self.tree.allocator;
        const data = try alloc.create(zig.Container);
        errdefer alloc.destroy(data);

        data.* = try zig.Container.init(alloc, ctx, closure);
        errdefer data.deinit(alloc);

        _ = try self.tree.appendNodePayload(self.parent, .block_code, usize, @intFromPtr(data));
    }
};

pub const StyledAuthor = struct {
    tree: *MutableTree,
    parent: srct.NodeHandle,
    callback: ?Callback = null,

    const CallbackFn = *const fn (ctx: *anyopaque, node: srct.NodeHandle, index: usize, length: usize) anyerror!void;

    const Callback = struct {
        index: usize,
        context: *anyopaque,
        func: CallbackFn,
        length: usize = 0,

        pub fn increment(self: *Callback, length: usize) void {
            self.length += if (self.length == 0) length else length + 1;
        }

        pub fn invoke(self: Callback, parent: srct.NodeHandle) !void {
            try self.func(self.context, parent, self.index, self.length);
        }
    };

    pub fn deinit(self: StyledAuthor) void {
        self.tree.dropNode(self.parent);
    }

    pub fn seal(self: StyledAuthor) !void {
        if (self.callback) |cb| try cb.invoke(self.parent);
    }

    pub fn plain(self: *StyledAuthor, text: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .inline_plain, []const u8, text);
        if (self.callback) |*cb| cb.increment(text.len);
    }

    pub fn plainFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .inline_plain);
        errdefer self.tree.dropNode(node);

        const len = try self.tree.setPayloadFmt(node, format, args);
        if (self.callback) |*cb| cb.increment(len);
    }

    pub fn italic(self: *StyledAuthor, text: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .inline_italic, []const u8, text);
        if (self.callback) |*cb| cb.increment(2 + text.len);
    }

    pub fn italicFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .inline_italic);
        errdefer self.tree.dropNode(node);

        const len = try self.tree.setPayloadFmt(node, format, args);
        if (self.callback) |*cb| cb.increment(2 + len);
    }

    pub fn italicStyled(self: *StyledAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .inline_italic),
        };
    }

    pub fn bold(self: *StyledAuthor, text: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .inline_bold, []const u8, text);
        if (self.callback) |*cb| cb.increment(4 + text.len);
    }

    pub fn boldFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .inline_bold);
        errdefer self.tree.dropNode(node);

        const len = try self.tree.setPayloadFmt(node, format, args);
        if (self.callback) |*cb| cb.increment(4 + len);
    }

    pub fn boldStyled(self: *StyledAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .inline_bold),
        };
    }

    pub fn boldItalic(self: *StyledAuthor, text: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .inline_bold_italic, []const u8, text);
        if (self.callback) |*cb| cb.increment(6 + text.len);
    }

    pub fn boldItalicFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .inline_bold_italic);
        errdefer self.tree.dropNode(node);

        const len = try self.tree.setPayloadFmt(node, format, args);
        if (self.callback) |*cb| cb.increment(6 + len);
    }

    pub fn boldItalicStyled(self: *StyledAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .inline_bold_italic),
        };
    }

    pub fn code(self: *StyledAuthor, text: []const u8) !void {
        _ = try self.tree.appendNodePayload(self.parent, .inline_code, []const u8, text);
        if (self.callback) |*cb| cb.increment(2 + text.len);
    }

    pub fn codeFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNode(self.parent, .inline_code);
        errdefer self.tree.dropNode(node);

        const len = try self.tree.setPayloadFmt(node, format, args);
        if (self.callback) |*cb| cb.increment(2 + len);
    }

    pub fn codeStyled(self: *StyledAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .inline_code),
        };
    }

    pub fn link(self: *StyledAuthor, href: []const u8, title: ?[]const u8, text: []const u8) !void {
        const node = try self.tree.appendNodePayload(self.parent, .inline_link, MarkLink, .{
            .href = href,
            .title = title orelse "",
        });
        errdefer self.tree.dropNode(node);

        _ = try self.tree.appendNodePayload(node, .inline_plain, []const u8, text);
        if (self.callback) |*cb| cb.increment(4 + href.len + text.len);
    }

    pub fn linkFmt(self: *StyledAuthor, href: []const u8, title: ?[]const u8, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.appendNodePayload(self.parent, .inline_link, MarkLink, .{
            .href = href,
            .title = title orelse "",
        });
        errdefer self.tree.dropNode(node);

        const child = try self.tree.appendNode(node, .inline_plain);
        errdefer self.tree.dropNode(child);

        const len = try self.tree.setPayloadFmt(child, format, args);
        if (self.callback) |*cb| cb.increment(4 + href.len + len);
    }

    pub fn linkStyled(self: *StyledAuthor, href: []const u8, title: ?[]const u8) !StyledAuthor {
        const node = try self.tree.appendNodePayload(self.parent, .inline_link, MarkLink, .{
            .href = href,
            .title = title orelse "",
        });

        if (self.callback) |*cb| {
            cb.increment(4 + href.len);
            return StyledAuthor{
                .tree = self.tree,
                .parent = node,
                .callback = .{
                    .index = 0,
                    .context = self,
                    .func = increment,
                },
            };
        } else {
            return StyledAuthor{
                .tree = self.tree,
                .parent = node,
            };
        }
    }

    fn increment(ctx: *anyopaque, _: srct.NodeHandle, _: usize, length: usize) !void {
        const self: *StyledAuthor = @ptrCast(@alignCast(ctx));
        self.callback.?.increment(length);
    }
};

pub const ListAuthor = struct {
    tree: *MutableTree,
    parent: srct.NodeHandle,

    pub fn deinit(self: ListAuthor) void {
        self.tree.dropNode(self.parent);
    }

    pub fn text(self: ListAuthor, value: []const u8) !void {
        const child = try self.tree.appendNode(self.parent, .block_list_item);
        errdefer self.tree.dropNode(child);

        _ = try self.tree.appendNodePayload(child, .inline_plain, []const u8, value);
    }

    pub fn textFmt(self: ListAuthor, comptime format: []const u8, args: anytype) !void {
        const child = try self.tree.appendNode(self.parent, .block_list_item);
        errdefer self.tree.dropNode(child);

        _ = try self.tree.appendNodePayloadFmt(child, .inline_plain, format, args);
    }

    pub fn textStyled(self: ListAuthor) !StyledAuthor {
        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_list_item),
        };
    }

    pub fn container(self: ListAuthor) !ContainerAuthor {
        return ContainerAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_list_item),
        };
    }

    pub fn list(self: ListAuthor, kind: ListKind) !ListAuthor {
        return ListAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNodePayload(self.parent, .block_list, ListKind, kind),
        };
    }
};

pub const TableAuthor = struct {
    tree: *MutableTree,
    parent: srct.NodeHandle,
    columns_sealed: bool = false,
    columns: std.ArrayListUnmanaged(MarkColumn) = .{},

    pub fn deinit(self: *TableAuthor) void {
        self.columns.deinit(self.tree.allocator);
        self.tree.dropNode(self.parent);
    }

    pub fn seal(self: *TableAuthor) !void {
        const tree = self.tree.view();
        const col_len = self.columns.items.len;
        if (col_len == 0) return error.EmptyTable;
        if (col_len > MAX_TABLE_COLUMNS) return error.TooManyTableColumns;
        if (col_len == tree.countChildren(self.parent)) return error.EmptyTable;

        // TODO: This is hacky...
        for (self.columns.items, 0..) |col, i| {
            const child = tree.childAt(self.parent, i);
            try self.tree.setPayload(child, MarkColumn, col);
        }

        try self.tree.setPayload(self.parent, u8, @truncate(col_len));
        self.columns.deinit(self.tree.allocator);
    }

    pub fn column(self: *TableAuthor, aligns: ColumnAlign, value: []const u8) !void {
        if (value.len > 255) return error.CellValueTooLong;
        if (self.columns_sealed) return error.TableColumnAfterRows;

        try self.columns.append(self.tree.allocator, MarkColumn{
            .aligns = aligns,
            .self_width = @truncate(value.len),
            .dynamic_width = @truncate(value.len),
        });
        errdefer _ = self.columns.pop();

        const child = try self.tree.appendNodePayload(self.parent, .block_table_column, MarkColumn, .{});
        errdefer self.tree.dropNode(child);

        _ = try self.tree.appendNodePayload(child, .inline_plain, []const u8, value);
    }

    pub fn columnFmt(self: *TableAuthor, aligns: ColumnAlign, comptime format: []const u8, args: anytype) !void {
        if (self.columns_sealed) return error.TableColumnAfterRows;

        const child = try self.tree.appendNodePayload(self.parent, .block_table_column, MarkColumn, .{});
        errdefer self.tree.dropNode(child);

        const text = try self.tree.appendNode(child, .inline_plain);
        errdefer self.tree.dropNode(text);

        const len = try self.tree.setPayloadFmt(text, format, args);
        if (len > 255) return error.CellValueTooLong;

        try self.columns.append(self.tree.allocator, MarkColumn{
            .aligns = aligns,
            .self_width = @truncate(len),
            .dynamic_width = @truncate(len),
        });
    }

    pub fn columnStyled(self: *TableAuthor, aligns: ColumnAlign) !StyledAuthor {
        if (self.columns_sealed) return error.TableColumnAfterRows;

        const column_index = self.columns.items.len;
        try self.columns.append(self.tree.allocator, MarkColumn{ .aligns = aligns });
        errdefer _ = self.columns.pop();

        return StyledAuthor{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_table_column),
            .callback = .{
                .context = self,
                .index = column_index,
                .func = setStyledColumnWidth,
            },
        };
    }

    fn setStyledColumnWidth(ctx: *anyopaque, node: srct.NodeHandle, index: usize, width: usize) !void {
        if (width > 255) return error.CellValueTooLong;
        const self: *TableAuthor = @ptrCast(@alignCast(ctx));

        try self.tree.setPayload(node, MarkColumn, .{});

        const col = &self.columns.items[index];
        col.self_width = @truncate(width);
        col.dynamic_width = @truncate(width);
    }

    pub fn rowText(self: *TableAuthor, cells: []const []const u8) !void {
        if (cells.len != self.columns.items.len) return error.RowColumnsMismatch;

        const tbl_row = try self.tree.appendNode(self.parent, .block_table_row);
        errdefer self.tree.dropNode(tbl_row);

        for (cells, 0..) |cell, i| {
            if (cell.len > 255) return error.CellValueTooLong;

            const child = try self.tree.appendNodePayload(tbl_row, .block_table_cell, u8, @truncate(cell.len));
            errdefer self.tree.dropNode(child);

            _ = try self.tree.appendNodePayload(child, .inline_plain, []const u8, cell);

            const col = &self.columns.items[i];
            if (cell.len > col.dynamic_width) col.dynamic_width = @truncate(cell.len);
        }

        self.columns_sealed = true;
    }

    pub fn row(self: *TableAuthor) !Row {
        self.columns_sealed = true;
        return Row{
            .tree = self.tree,
            .parent = try self.tree.appendNode(self.parent, .block_table_row),
            .columns = &self.columns,
        };
    }

    pub const Row = struct {
        tree: *MutableTree,
        parent: srct.NodeHandle,
        columns: *std.ArrayListUnmanaged(MarkColumn),

        pub fn deinit(self: Row) void {
            self.tree.dropNode(self.parent);
        }

        pub fn cell(self: Row, value: []const u8) !void {
            const col_index = self.tree.view().countChildren(self.parent);
            if (col_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const col = &self.columns.items[col_index];
            const child = try self.tree.appendNodePayload(self.parent, .block_table_cell, u8, @truncate(value.len));
            errdefer self.tree.dropNode(child);

            _ = try self.tree.appendNodePayload(child, .inline_plain, []const u8, value);

            if (value.len > col.dynamic_width) col.dynamic_width = @truncate(value.len);
        }

        pub fn cellFmt(self: Row, comptime format: []const u8, args: anytype) !void {
            const col_index = self.tree.view().countChildren(self.parent);
            if (col_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const col = &self.columns.items[col_index];
            const child = try self.tree.appendNode(self.parent, .block_table_cell);
            errdefer self.tree.dropNode(child);

            const text = try self.tree.appendNode(child, .inline_plain);
            errdefer self.tree.dropNode(text);

            const width = try self.tree.setPayloadFmt(text, format, args);
            if (width > col.dynamic_width) col.dynamic_width = @truncate(width);

            try self.tree.setPayload(child, u8, @truncate(width));
        }

        pub fn cellStyled(self: *Row) !StyledAuthor {
            const col_index = self.tree.view().countChildren(self.parent);
            if (col_index >= self.columns.items.len) return error.RowColumnsMismatch;

            return StyledAuthor{
                .tree = self.tree,
                .parent = try self.tree.appendNode(self.parent, .block_table_cell),
                .callback = .{
                    .context = self,
                    .index = col_index,
                    .func = updateStyledCellWidth,
                },
            };
        }

        fn updateStyledCellWidth(ctx: *anyopaque, node: srct.NodeHandle, index: usize, width: usize) !void {
            if (width > 255) return error.CellValueTooLong;
            const self: *Row = @ptrCast(@alignCast(ctx));
            try self.tree.setPayload(node, u8, @truncate(width));

            const col = &self.columns.items[index];
            if (width > col.dynamic_width) col.dynamic_width = @truncate(width);
        }
    };
};

test "MutableDocument: Raw" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        try md.root().raw("foo");
        try md.root().rawFmt("bar {d}", .{108});

        break :blk try md.toReadOnly(test_alloc);
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\foo
        \\
        \\bar 108
    , doc);
}

test "MutableDocument: Comment" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        try md.root().comment("foo");
        try md.root().commentFmt("bar {d}", .{108});

        break :blk try md.toReadOnly(test_alloc);
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\<!-- foo -->
        \\
        \\<!-- bar 108 -->
    , doc);
}

test "MutableDocument: Paragraph & Text" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        try md.root().paragraph("foo");
        try md.root().paragraphFmt("bar{d}", .{108});

        var style = try md.root().paragraphStyled();
        errdefer style.deinit();
        try style.plain("text");
        try style.plainFmt("text{d}", .{108});

        try style.italic("italic");
        try style.italicFmt("italic {d}", .{108});
        var sub_style = try style.italicStyled();
        errdefer sub_style.deinit();
        try sub_style.plain("italic style");
        try sub_style.seal();

        try style.bold("bold");
        try style.boldFmt("bold {d}", .{108});
        sub_style = try style.boldStyled();
        try sub_style.plain("bold style");
        try sub_style.seal();

        try style.boldItalic("bold italic");
        try style.boldItalicFmt("bold italic {d}", .{108});
        sub_style = try style.boldItalicStyled();
        try sub_style.plain("bold italic style");
        try sub_style.seal();

        try style.code("code");
        try style.codeFmt("code {d}", .{108});
        sub_style = try style.codeStyled();
        try sub_style.plain("code style");
        try sub_style.seal();

        try style.link("#", "title", "link");
        try style.linkFmt("#", null, "link {d}", .{108});
        sub_style = try style.linkStyled("#", null);
        try sub_style.plain("link style");
        try sub_style.seal();

        try style.seal();
        break :blk try md.toReadOnly(test_alloc);
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\foo
        \\
        \\bar108
        \\
        \\text text108 _italic_ _italic 108_ _italic style_ **bold** **bold 108** **bold style**
    ++ " ***bold italic*** ***bold italic 108*** ***bold italic style*** `code` `code 108` `code style`" ++
        " [link](# \"title\") [link 108](#) [link style](#)", doc);
}

test "MutableDocument: Heading" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        try md.root().heading(2, "Foo");
        try md.root().headingFmt(4, "Bar {d}", .{108});

        var style = try md.root().headingStyled(6);
        try style.plain("Baz Style");
        try style.seal();

        break :blk try md.toReadOnly(test_alloc);
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\## Foo
        \\
        \\#### Bar 108
        \\
        \\###### Baz Style
    , doc);
}

test "MutableDocument: Quote" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        try md.root().quote("foo");
        try md.root().quoteFmt("bar {d}", .{108});

        var style = try md.root().quoteStyled();
        try style.plain("baz style");
        try style.seal();

        var container = try md.root().quoteContainer();
        try container.paragraph("qux 0");
        try container.paragraph("qux 1");

        break :blk try md.toReadOnly(test_alloc);
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

test "MutableDocument: Code" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const doc = blk: {
        var md = try MutableDocument.init(arena_alloc);
        errdefer md.deinit();

        try md.root().code(struct {
            fn f(_: *zig.ContainerBuild) !void {}
        }.f);

        break :blk try md.toReadOnly(arena_alloc);
    };
    defer doc.deinit(arena_alloc);
    try Writer.expectValue(
        \\```zig
        \\
        \\```
    , doc);
}

test "MutableDocument: List" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        const list = try md.root().list(.unordered);
        try list.text("foo");
        try list.textFmt("bar {d}", .{108});

        var style = try list.textStyled();
        try style.plain("baz style");
        try style.seal();

        const sublist = try list.list(.ordered);
        try sublist.text("first");
        try sublist.text("second");

        var container = try list.container();
        try container.paragraph("qux");
        try container.paragraph("paragraph");

        break :blk try md.toReadOnly(test_alloc);
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

test "MutableDocument: Table" {
    const doc = blk: {
        var md = try MutableDocument.init(test_alloc);
        errdefer md.deinit();

        {
            var table = try md.root().table();
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
            }

            try table.seal();
        }

        break :blk try md.toReadOnly(test_alloc);
    };
    defer doc.deinit(test_alloc);
    try Writer.expectValue(
        \\| A   | B 108   | C Style |
        \\|----:|:-------:|:--------|
        \\| foo | bar     | baz     |
        \\| foo | bar 108 | baz     |
    , doc);
}

test "html" {
    _ = html;
}
