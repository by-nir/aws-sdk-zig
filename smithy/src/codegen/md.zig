const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const dcl = @import("../utils/declarative.zig");
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

// TODO: Support soft/hard width guidelines

pub const DocumentClosure = *const fn (*Document.Build) anyerror!void;
pub const Document = struct {
    blocks: []const Block,

    pub fn init(
        allocator: Allocator,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), DocumentClosure),
    ) !Document {
        var build = Document.Build{ .allocator = allocator };
        errdefer build.deinit(allocator);
        try callClosure(ctx, closure, .{&build});
        return build.consume();
    }

    pub fn deinit(self: Document, allocator: Allocator) void {
        for (self.blocks) |t| t.deinit(allocator);
        allocator.free(self.blocks);
    }

    pub fn write(self: Document, writer: *Writer) !void {
        for (self.blocks, 0..) |block, i| {
            if (i == 0) {
                try writer.appendValue(block);
            } else {
                // Empty line padding, unless previous is a comment
                if (self.blocks[i - 1] != .comment) try writer.breakEmpty(1);
                try writer.breakValue(block);
            }
        }
    }

    pub const Build = struct {
        allocator: Allocator,
        blocks: std.ArrayListUnmanaged(Block) = .{},

        pub fn deinit(self: *Build, allocator: Allocator) void {
            for (self.blocks.items) |t| t.deinit(allocator);
            self.blocks.deinit(allocator);
        }

        pub fn consume(self: *Build) !Document {
            const blocks = try self.blocks.toOwnedSlice(self.allocator);
            return .{ .blocks = blocks };
        }

        pub fn raw(self: *Build, text: []const u8) !void {
            try self.blocks.append(self.allocator, .{ .raw = text });
        }

        pub fn rawFmt(self: *Build, comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(self.allocator, fmt, args);
            try self.blocks.append(self.allocator, .{ .raw_alloc = text });
        }

        pub fn comment(self: *Build, text: []const u8) !void {
            try self.blocks.append(self.allocator, .{ .comment = text });
        }

        pub fn heading(self: *Build, level: u8, text: []const u8) !void {
            try self.blocks.append(self.allocator, .{ .heading = .{
                .level = level,
                .text = text,
            } });
        }

        pub fn paragraph(self: *Build) Formated.Build(*Build, anyerror!void) {
            return .{
                .allocator = self.allocator,
                .callback = createCallback(self, endParagraph),
            };
        }

        fn endParagraph(self: *Build, formated: Formated) !void {
            try self.blocks.append(self.allocator, .{ .paragraph = formated });
        }

        pub fn quote(self: *Build) Formated.Build(*Build, anyerror!void) {
            return .{
                .allocator = self.allocator,
                .callback = createCallback(self, endQuote),
            };
        }

        fn endQuote(self: *Build, formated: Formated) !void {
            try self.blocks.append(self.allocator, .{ .quote = formated });
        }

        pub fn list(self: *Build, kind: List.Kind, closure: ListClosure) !void {
            try self.listWith(kind, {}, closure);
        }

        pub fn listWith(
            self: *Build,
            kind: List.Kind,
            ctx: anytype,
            closure: Closure(@TypeOf(ctx), ListClosure),
        ) !void {
            const data = try List.init(self.allocator, kind, ctx, closure);
            errdefer data.deinit(self.allocator);
            try self.blocks.append(self.allocator, .{ .list = data });
        }

        pub fn table(self: *Build, closure: TableClosure) !void {
            try self.tableWith({}, closure);
        }

        pub fn tableWith(
            self: *Build,
            ctx: anytype,
            closure: Closure(@TypeOf(ctx), TableClosure),
        ) !void {
            const data = try Table.init(self.allocator, ctx, closure);
            errdefer data.deinit(self.allocator);
            try self.blocks.append(self.allocator, .{ .table = data });
        }

        pub fn code(self: *Build, closure: zig.ContainerClosure) !void {
            try self.codeWith({}, closure);
        }

        pub fn codeWith(
            self: *Build,
            ctx: anytype,
            closure: Closure(@TypeOf(ctx), zig.ContainerClosure),
        ) !void {
            const data = try zig.Container.init(self.allocator, ctx, closure);
            errdefer data.deinit(self.allocator);
            try self.blocks.append(self.allocator, .{ .code = data });
        }
    };
};

pub const Block = union(enum) {
    raw: []const u8,
    raw_alloc: []const u8,
    comment: []const u8,
    heading: Heading,
    paragraph: Formated,
    quote: Formated,
    list: List,
    table: Table,
    code: zig.Container,

    pub fn deinit(self: Block, allocator: Allocator) void {
        switch (self) {
            .raw, .comment, .heading => {},
            .raw_alloc => |t| allocator.free(t),
            inline else => |t| t.deinit(allocator),
        }
    }

    pub fn write(self: Block, writer: *Writer) !void {
        switch (self) {
            .raw, .raw_alloc => |text| try writer.appendString(text),
            .comment => |s| {
                try writer.appendFmt("<!-- {s} -->", .{s});
            },
            .paragraph => |text| try text.write(writer),
            .quote => |text| {
                try writer.pushIndent("> ");
                defer writer.popIndent();
                try writer.appendString("> ");
                try text.write(writer);
            },
            .code => |code| {
                try writer.appendString("```zig\n");
                try code.write(writer);
                try writer.breakString("```");
            },
            inline else => |t| try t.write(writer),
        }
    }
};

pub const Formated = struct {
    segments: []const Segment,

    pub fn deinit(self: Formated, allocator: Allocator) void {
        allocator.free(self.segments);
    }

    pub fn write(self: Formated, writer: *Writer) !void {
        for (self.segments, 0..) |segment, i| {
            std.debug.assert(segment.text.len > 0);
            if (i == 0 or std.mem.indexOfScalar(u8, ".,;:?!", segment.text[0]) != null) {
                try writer.appendValue(segment);
            } else {
                try writer.appendFmt(" {}", .{segment});
            }
        }
    }

    pub const Style = union(enum) {
        plain,
        italic,
        bold,
        bold_italic,
        code,
        link: []const u8,
    };

    pub const Segment = struct {
        text: []const u8,
        format: Style,

        pub fn write(self: Segment, writer: *Writer) !void {
            switch (self.format) {
                .plain => try writer.appendString(self.text),
                .italic => try writer.appendFmt("_{s}_", .{self.text}),
                .bold => try writer.appendFmt("**{s}**", .{self.text}),
                .bold_italic => try writer.appendFmt("***{s}***", .{self.text}),
                .code => try writer.appendFmt("`{s}`", .{self.text}),
                .link => |url| try writer.appendFmt(
                    "[{s}]({s})",
                    .{ self.text, url },
                ),
            }
        }
    };

    pub fn Build(comptime Context: type, comptime Return: type) type {
        const Callback = Cb(Context, Formated, Return);
        return struct {
            const Self = @This();

            allocator: Allocator,
            callback: Callback,
            chain: StackChain(?Segment) = .{},

            fn append(self: *const Self, text: Segment) Self {
                var dupe = self.*;
                dupe.chain = self.chain.append(text);
                return dupe;
            }

            pub fn plain(self: *const Self, text: []const u8) Self {
                return self.append(.{
                    .text = text,
                    .format = .plain,
                });
            }

            pub fn italic(self: *const Self, text: []const u8) Self {
                return self.append(.{
                    .text = text,
                    .format = .italic,
                });
            }

            pub fn bold(self: *const Self, text: []const u8) Self {
                return self.append(.{
                    .text = text,
                    .format = .bold,
                });
            }

            pub fn boldItalic(self: *const Self, text: []const u8) Self {
                return self.append(.{
                    .text = text,
                    .format = .bold_italic,
                });
            }

            pub fn code(self: *const Self, text: []const u8) Self {
                return self.append(.{
                    .text = text,
                    .format = .code,
                });
            }

            pub fn link(self: *const Self, text: []const u8, url: []const u8) Self {
                return self.append(.{
                    .text = text,
                    .format = .{ .link = url },
                });
            }

            pub fn end(self: Self) Callback.Return {
                if (self.chain.unwrapAlloc(self.allocator)) |segments| {
                    return self.callback.invoke(.{ .segments = segments });
                } else |err| {
                    return self.callback.fail(err);
                }
            }
        };
    }
};

test "raw" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.raw("foo");
    try build.rawFmt("bar {s}", .{"baz"});
    try Writer.expectValue("foo", build.blocks.items[0]);
    try Writer.expectValue("bar baz", build.blocks.items[1]);
}

test "Formated" {
    const Test = struct {
        fn end(_: void, text: Formated) !void {
            defer text.deinit(test_alloc);
            const seg = text.segments;
            try Writer.expectValue("foo", seg[0]);
            try Writer.expectValue("_bar_", seg[1]);
            try Writer.expectValue("**baz**", seg[2]);
            try Writer.expectValue("***qux***", seg[3]);
            try Writer.expectValue("`foo`", seg[4]);
            try Writer.expectValue("[bar](baz)", seg[5]);
        }
    };

    try (Formated.Build(void, anyerror!void){
        .allocator = test_alloc,
        .callback = createCallback({}, Test.end),
    }).plain("foo").italic("bar").bold("baz").boldItalic("qux")
        .code("foo").link("bar", "baz").end();
}

test "comment" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.comment("foo");
    try Writer.expectValue("<!-- foo -->", build.blocks.items[0]);
}

pub const Heading = struct {
    level: u8,
    text: []const u8,

    pub fn write(self: Heading, writer: *Writer) !void {
        std.debug.assert(self.level > 0 and self.level <= 3);
        const level = "###"[3 - self.level .. 3];
        try writer.appendFmt("{s} {s}", .{ level, self.text });
    }
};

test "heading" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.heading(2, "foo");
    try Writer.expectValue("## foo", build.blocks.items[0]);
}

test "paragraph" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.paragraph().plain("foo").end();
    try Writer.expectValue("foo", build.blocks.items[0]);
}

test "quote" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.quote().plain("foo").end();
    try Writer.expectValue("> foo", build.blocks.items[0]);
}

pub const ListClosure = *const fn (*List.Build) anyerror!void;
pub const List = struct {
    kind: Kind,
    items: []const Item,

    pub const Kind = enum { unordered, ordered };

    pub const Item = union(enum) {
        plain: []const u8,
        formated: Formated,
        list: List,

        pub fn deinit(self: Item, allocator: Allocator) void {
            switch (self) {
                .plain => {},
                inline else => |t| t.deinit(allocator),
            }
        }

        pub fn write(self: Item, writer: *Writer) !void {
            switch (self) {
                .plain => |text| try writer.appendString(text),
                inline else => |t| try t.write(writer),
            }
        }
    };

    pub fn init(
        allocator: Allocator,
        kind: Kind,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), ListClosure),
    ) !List {
        var build = List.Build.init(allocator, kind);
        errdefer build.deinit();
        try callClosure(ctx, closure, .{&build});
        return try build.consume();
    }

    pub fn deinit(self: List, allocator: Allocator) void {
        for (self.items) |t| t.deinit(allocator);
        allocator.free(self.items);
    }

    pub fn write(self: List, writer: *Writer) anyerror!void {
        std.debug.assert(self.items.len > 0);
        switch (self.kind) {
            .unordered => for (self.items, 0..) |item, i| {
                if (i > 0) try writer.breakString("");
                switch (item) {
                    .plain => |s| try writer.appendFmt("- {s}", .{s}),
                    .formated => |t| try writer.appendFmt("- {}", .{t}),
                    .list => |t| try writeSubList(t, writer),
                }
            },
            .ordered => for (self.items, 1..) |item, i| {
                if (i > 1) try writer.breakString("");
                switch (item) {
                    .plain => |s| try writer.appendFmt("{d}. {s}", .{ i, s }),
                    .formated => |t| try writer.appendFmt("{d}. {}", .{ i, t }),
                    .list => |t| try writeSubList(t, writer),
                }
            },
        }
    }

    fn writeSubList(self: List, writer: *Writer) !void {
        try writer.pushIndent("  ");
        defer writer.popIndent();
        try writer.appendFmt("  {}", .{self});
    }

    pub const Build = struct {
        allocator: Allocator,
        kind: List.Kind,
        items: std.ArrayListUnmanaged(Item) = .{},

        pub fn init(allocator: Allocator, kind: List.Kind) Build {
            return .{ .allocator = allocator, .kind = kind };
        }

        pub fn deinit(self: *Build) void {
            self.deinit();
        }

        pub fn consume(self: *Build) !List {
            const items = try self.items.toOwnedSlice(self.allocator);
            return .{ .kind = self.kind, .items = items };
        }

        pub fn plain(self: *Build, text: []const u8) !void {
            try self.items.append(self.allocator, .{ .plain = text });
        }

        pub fn formated(self: *Build) Formated.Build(*Build, anyerror!void) {
            return .{
                .allocator = self.allocator,
                .callback = createCallback(self, endFormated),
            };
        }

        fn endFormated(self: *Build, text: Formated) !void {
            try self.items.append(self.allocator, .{ .formated = text });
        }

        pub fn subList(self: *Build, kind: List.Kind, closure: ListClosure) !void {
            try self.subListWith(kind, {}, closure);
        }

        pub fn subListWith(
            self: *Build,
            kind: List.Kind,
            ctx: anytype,
            closure: Closure(@TypeOf(ctx), ListClosure),
        ) !void {
            std.debug.assert(self.items.items.len > 0); // First item can’t be a sub-list
            const data = try List.init(self.allocator, kind, {}, closure);
            errdefer data.deinit(self.allocator);
            try self.items.append(self.allocator, .{ .list = data });
        }
    };
};

test "list" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.list(.unordered, struct {
        fn f(b: *List.Build) !void {
            try b.plain("foo");
            try b.formated().plain("bar").end();
            try b.subList(.ordered, struct {
                fn f(sub: *List.Build) !void {
                    try sub.plain("baz");
                    try sub.formated().plain("qux").end();
                }
            }.f);
        }
    }.f);

    try Writer.expectValue(
        \\- foo
        \\- bar
        \\  1. baz
        \\  2. qux
    , build.blocks.items[0]);
}

pub const TableClosure = *const fn (*Table.Build) anyerror!void;
pub const Table = struct {
    columns: []const Column,
    rows: []const Row,

    pub const Align = enum { left, center, right };

    pub const Column = struct {
        name: []const u8,
        width: u8,
        alignment: Align,
    };

    pub const Row = struct {
        cells: []const []const u8,

        pub fn deinit(self: Row, allocator: Allocator) void {
            allocator.free(self.cells);
        }
    };

    pub fn init(
        allocator: Allocator,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), TableClosure),
    ) !Table {
        var build = Table.Build{ .allocator = allocator };
        errdefer build.deinit();
        try callClosure(ctx, closure, .{&build});
        return build.consume();
    }

    pub fn deinit(self: Table, allocator: Allocator) void {
        for (self.rows) |t| t.deinit(allocator);
        allocator.free(self.rows);
        allocator.free(self.columns);
    }

    pub fn write(self: Table, writer: *Writer) !void {
        const separator: [254]u8 = comptime blk: {
            var buf: [254]u8 = undefined;
            @memset(&buf, '-');
            break :blk buf;
        };

        std.debug.assert(self.rows.len > 0);
        std.debug.assert(self.columns.len > 0);

        // Header
        try writer.appendChar('|');
        for (self.columns) |col| {
            try writeCell(writer, col.name, col.width);
        }

        // Separator
        try writer.breakChar('|');
        for (self.columns) |col| {
            switch (col.alignment) {
                .left => try writer.appendFmt(
                    ":{s}|",
                    .{separator[0 .. col.width + 1]},
                ),
                .center => try writer.appendFmt(
                    ":{s}:|",
                    .{separator[0..col.width]},
                ),
                .right => try writer.appendFmt(
                    "{s}:|",
                    .{separator[0 .. col.width + 1]},
                ),
            }
        }

        // Rows
        for (self.rows) |row| {
            try writer.breakChar('|');
            for (row.cells, 0..) |cell, i| {
                const width = self.columns[i].width;
                try writeCell(writer, cell, width);
            }
        }
    }

    fn writeCell(writer: *Writer, text: []const u8, width: u8) !void {
        const whitespace: [255]u8 = comptime blk: {
            var buf: [255]u8 = undefined;
            @memset(&buf, ' ');
            break :blk buf;
        };

        try writer.appendFmt(
            " {s}{s} |",
            .{ text, whitespace[0 .. width - text.len] },
        );
    }

    pub const Build = struct {
        allocator: Allocator,
        columns: std.ArrayListUnmanaged(Column) = .{},
        rows: std.ArrayListUnmanaged(Row) = .{},

        pub fn deinit(self: *Build) void {
            for (self.rows.items) |t| t.deinit(self.allocator);
            self.rows.deinit(self.allocator);
            self.columns.deinit(self.allocator);
        }

        pub fn consume(self: *Build) !Table {
            const rows = try self.rows.toOwnedSlice(self.allocator);
            errdefer {
                for (rows) |t| t.deinit(self.allocator);
                self.allocator.free(rows);
            }
            const columns = try self.columns.toOwnedSlice(self.allocator);
            return .{ .columns = columns, .rows = rows };
        }

        pub fn column(self: *Build, name: []const u8, alignment: Table.Align) !void {
            std.debug.assert(name.len <= 255);
            std.debug.assert(self.rows.items.len == 0);
            try self.columns.append(self.allocator, .{
                .name = name,
                .width = @truncate(name.len),
                .alignment = alignment,
            });
        }

        pub fn row(self: *Build, cells: []const []const u8) !void {
            std.debug.assert(cells.len == self.columns.items.len);
            const alloc_cells = try self.allocator.dupe([]const u8, cells);
            errdefer self.allocator.free(alloc_cells);
            try self.rows.append(self.allocator, .{ .cells = alloc_cells });

            for (cells, 0..) |cell, i| {
                std.debug.assert(cell.len <= 255);
                const width: u8 = @truncate(cell.len);
                if (width > self.columns.items[i].width) {
                    self.columns.items[i].width = width;
                }
            }
        }
    };
};

test "table" {
    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.table(struct {
        fn f(b: *Table.Build) !void {
            try b.column("A", .right);
            try b.column("B", .center);
            try b.column("C", .left);

            try b.row(&.{ "A01 Foo!", "B01", "C01" });
            try b.row(&.{ "A02", "B02 Bar Baz", "C02" });
            try b.row(&.{ "A03", "B03", "C03 Qux" });
        }
    }.f);

    try Writer.expectValue(
        \\| A        | B           | C       |
        \\|---------:|:-----------:|:--------|
        \\| A01 Foo! | B01         | C01     |
        \\| A02      | B02 Bar Baz | C02     |
        \\| A03      | B03         | C03 Qux |
    , build.blocks.items[0]);
}

test "code" {
    const Test = struct {
        fn code(b: *zig.ContainerBuild) !void {
            try b.commentMarkdown(.doc, comment);
            try b.constant("foo").assign(b.x.raw("bar"));
        }

        fn comment(b: *Document.Build) !void {
            try b.heading(1, "Baz");
            try b.paragraph().plain("Qux...").end();
        }
    };

    var build = Document.Build{ .allocator = test_alloc };
    defer build.deinit(test_alloc);
    try build.code(Test.code);

    try Writer.expectValue(
        \\```zig
        \\/// # Baz
        \\///
        \\/// Qux...
        \\const foo = bar;
        \\```
    , build.blocks.items[0]);
}

const Mark = enum {
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

const MarkColumn = packed struct(u24) {
    aligns: Align,
    self_width: u8,
    dynamic_width: u8,

    pub const Align = enum(u8) { left, center, right };
};

pub const ListKind = enum(u8) { unordered, ordered };

const MAX_TABLE_COLUMNS = 16;

pub const NEW_Document = struct {
    tree: MarkTree,

    const INDENT = " " ** 4;

    pub fn author(allocator: Allocator) !DocumentAuthor {
        return DocumentAuthor.init(allocator);
    }

    pub fn deinit(self: NEW_Document, allocator: Allocator) void {
        self.tree.deinit(allocator);
    }

    pub fn write(self: NEW_Document, writer: *Writer) !void {
        var it = self.tree.iterate();
        if (it.next()) |node| try writeNode(node, writer);

        while (it.next()) |node| {
            try writeNodePrefix(false, writer);
            try writeNode(node, writer);
        }
    }

    fn writeNode(node: MarkTree.Node, writer: *Writer) anyerror!void {
        switch (node.tag) {
            .block_raw, .text_plain => try writer.appendString(node.payload),
            .text_italic => try writer.appendFmt("_{s}_", .{node.payload}),
            .text_bold => try writer.appendFmt("**{s}**", .{node.payload}),
            .text_bold_italic => try writer.appendFmt("***{s}***", .{node.payload}),
            .text_code => try writer.appendFmt("`{s}`", .{node.payload}),
            .text_link => {
                try writer.appendChar('[');
                try writeNodeChildren(node, .inlined, writer);
                try writer.appendFmt("]({s})", .{node.payload});
            },
            .block_comment => try writer.appendFmt("<!-- {s} -->", .{node.payload}),
            .block_paragraph => try writeNodeChildren(node, .inlined, writer),
            .block_heading => {
                std.debug.assert(node.payload.len == 1);
                const level: u8 = node.payload[0];
                std.debug.assert(level > 0 and level <= 6);

                try writer.appendString("####### "[7 - level .. 8]);
                try writeNodeChildren(node, .inlined, writer);
            },
            .block_quote => {
                try writer.pushIndent("> ");
                defer writer.popIndent();
                try writer.appendString("> ");
                try writeNodeChildren(node, .inlined, writer);
            },
            .block_code => {
                std.debug.assert(node.payload.len == @sizeOf(usize));
                const code: *const zig.Container = @ptrFromInt(std.mem.bytesToValue(usize, node.payload));

                try writer.appendString("```zig\n");
                try code.write(writer);
                try writer.breakString("```");
            },
            .block_list => {
                std.debug.assert(node.payload.len == 1);
                const kind: ListKind = @enumFromInt(node.payload[0]);

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
                std.debug.assert(node.payload.len == 1);
                const col_len = node.payload[0];

                const whitespace = " " ** 255;
                const separator = "-" ** 255;

                var widths: [MAX_TABLE_COLUMNS]u8 = undefined;

                // Header
                try writer.appendChar('|');
                for (0..col_len) |i| {
                    const col_node = node.child(@intCast(i)).?;
                    const column = std.mem.bytesAsValue(MarkColumn, col_node.payload);
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
                    const item = node.child(@intCast(i)).?;
                    const column = std.mem.bytesAsValue(MarkColumn, item.payload);
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
                        std.debug.assert(cell_node.payload.len == 1);
                        const padding = widths[i] - cell_node.payload[0];

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
                        try writer.pushIndent(INDENT);
                    }
                },
            }
        }
        defer if (concat == .inlined_or_indent and !inlined) writer.popIndent();

        while (it.next()) |node| {
            try writeNodePrefix(inlined, writer);
            try writeNode(node, writer);
        }
    }

    fn writeNodePrefix(inlined: bool, writer: *Writer) !void {
        if (inlined) {
            try writer.appendChar(' ');
        } else {
            try writer.breakEmpty(1);
            try writer.breakString("");
        }
    }
};

test "Document: Raw" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_raw);
            errdefer node.deinit();
            node.setPayload("foo");
            try node.seal();

            node = try tree.append(.block_raw);
            node.setPayload("bar");
            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
            node.setPayload("foo");
            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
            child.setPayload("text");
            try child.seal();

            child = try node.append(.text_italic);
            child.setPayload("italic");
            try child.seal();

            child = try node.append(.text_bold);
            child.setPayload("bold");
            try child.seal();

            child = try node.append(.text_bold_italic);
            child.setPayload("bold italic");
            try child.seal();

            child = try node.append(.text_code);
            child.setPayload("code");
            try child.seal();

            child = try node.append(.text_link);
            child.setPayload("#");
            var link_text = try child.append(.text_plain);
            errdefer link_text.deinit();
            link_text.setPayload("link");
            try link_text.seal();
            try child.seal();

            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
    };
    defer doc.deinit(test_alloc);

    try Writer.expectValue("text _italic_ **bold** ***bold italic*** `code` [link](#)", doc);
}

test "Document: Header" {
    const doc = blk: {
        var tree = try MarkTree.author(test_alloc);
        errdefer tree.deinit();

        {
            var node = try tree.append(.block_heading);
            errdefer node.deinit();
            node.setPayload(&.{@as(u8, 2)});

            var child = try node.append(.text_plain);
            errdefer child.deinit();
            child.setPayload("Foo");
            try child.seal();

            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
            child.setPayload("foo");
            try child.seal();

            try node.seal();

            node = try tree.append(.block_quote);

            var para = try node.append(.block_paragraph);
            errdefer para.deinit();
            child = try para.append(.text_plain);
            child.setPayload("bar");
            try child.seal();
            try para.seal();

            para = try node.append(.block_paragraph);
            child = try para.append(.text_plain);
            child.setPayload("baz");
            try child.seal();
            try para.seal();

            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
            node.setPayload(&std.mem.toBytes(@intFromPtr(&code)));

            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
            node.setPayload(&.{@intFromEnum(ListKind.unordered)});

            var item = try node.append(.block_list_item);
            errdefer item.deinit();
            var child = try item.append(.text_plain);
            errdefer child.deinit();
            child.setPayload("foo");
            try child.seal();
            try item.seal();

            item = try node.append(.block_list_item);

            var para = try item.append(.block_paragraph);
            errdefer para.deinit();
            child = try para.append(.text_plain);
            child.setPayload("bar");
            try child.seal();
            try para.seal();

            para = try item.append(.block_paragraph);
            child = try para.append(.text_plain);
            child.setPayload("baz");
            try child.seal();
            try para.seal();

            try item.seal();

            item = try node.append(.block_list_item);
            child = try item.append(.text_plain);
            child.setPayload("qux");
            try child.seal();
            try item.seal();

            try node.seal();

            node = try tree.append(.block_list);
            node.setPayload(&.{@intFromEnum(ListKind.ordered)});

            item = try node.append(.block_list_item);
            child = try item.append(.text_plain);
            child.setPayload("foo");
            try child.seal();
            try item.seal();

            item = try node.append(.block_list_item);
            child = try item.append(.text_plain);
            child.setPayload("bar");
            try child.seal();
            try item.seal();

            var sublist = try node.append(.block_list);
            sublist.setPayload(&.{@intFromEnum(ListKind.ordered)});

            item = try sublist.append(.block_list_item);
            child = try item.append(.text_plain);
            child.setPayload("baz");
            try child.seal();
            try item.seal();

            item = try sublist.append(.block_list_item);
            child = try item.append(.text_plain);
            child.setPayload("qux");
            try child.seal();
            try item.seal();

            try sublist.seal();
            try node.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
            table.setPayload(&.{3});

            var cell = try table.append(.block_table_column);
            errdefer cell.deinit();
            cell.setPayload(&std.mem.toBytes(MarkColumn{
                .aligns = .right,
                .self_width = 1,
                .dynamic_width = 8,
            }));
            var child = try cell.append(.text_plain);
            errdefer child.deinit();
            child.setPayload("A");
            try child.seal();
            try cell.seal();

            cell = try table.append(.block_table_column);
            cell.setPayload(&std.mem.toBytes(MarkColumn{
                .aligns = .center,
                .self_width = 1,
                .dynamic_width = 11,
            }));
            child = try cell.append(.text_plain);
            child.setPayload("B");
            try child.seal();
            try cell.seal();

            cell = try table.append(.block_table_column);
            cell.setPayload(&std.mem.toBytes(MarkColumn{
                .aligns = .left,
                .self_width = 1,
                .dynamic_width = 7,
            }));
            child = try cell.append(.text_plain);
            child.setPayload("C");
            try child.seal();
            try cell.seal();

            var row = try table.append(.block_table_row);
            errdefer row.deinit();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{8});
            child = try cell.append(.text_plain);
            child.setPayload("A01 Foo!");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{3});
            child = try cell.append(.text_plain);
            child.setPayload("B01");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{3});
            child = try cell.append(.text_plain);
            child.setPayload("C01");
            try child.seal();
            try cell.seal();

            try row.seal();
            row = try table.append(.block_table_row);

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{3});
            child = try cell.append(.text_plain);
            child.setPayload("A02");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{11});
            child = try cell.append(.text_plain);
            child.setPayload("B02 Bar Baz");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{3});
            child = try cell.append(.text_plain);
            child.setPayload("C02");
            try child.seal();
            try cell.seal();

            try row.seal();
            row = try table.append(.block_table_row);

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{3});
            child = try cell.append(.text_plain);
            child.setPayload("A03");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{3});
            child = try cell.append(.text_plain);
            child.setPayload("B03");
            try child.seal();
            try cell.seal();

            cell = try row.append(.block_table_cell);
            cell.setPayload(&.{7});
            child = try cell.append(.text_plain);
            child.setPayload("C03 Qux");
            try child.seal();
            try cell.seal();

            try row.seal();
            try table.seal();
        }

        break :blk NEW_Document{ .tree = try tree.consume() };
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
        return .{ .tree = MarkTreeAuthor.init(allocator) };
    }

    pub fn consume(self: *DocumentAuthor) !NEW_Document {
        return NEW_Document{ .tree = try self.tree.consume() };
    }

    pub fn raw(self: *DocumentAuthor, value: []const u8) !void {
        var node = try self.tree.append(.block_raw);
        errdefer node.deinit();
        node.setPayload(value);
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
        node.setPayload(text);
        try node.seal();
    }

    pub fn commentFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.tree.append(.block_comment);
        errdefer node.deinit();
        _ = try node.setPayloadFmt(format, args);
        try node.seal();
    }

    pub fn heading(self: *DocumentAuthor, level: u8, text: []const u8) !void {
        if (level == 0 or level > 6) return error.InvalidHeaderLevel;
        var node = try self.tree.append(.block_heading);
        errdefer node.deinit();
        _ = try node.setPayloadFmt("{c}{s}", .{ level, text });
        try node.seal();
    }

    pub fn headingFmt(self: *DocumentAuthor, level: u8, comptime format: []const u8, args: anytype) !void {
        if (level == 0 or level > 6) return error.InvalidHeaderLevel;
        var node = try self.tree.append(.block_heading);
        errdefer node.deinit();
        _ = try node.setPayloadFmt("{c}" ++ format, .{level} ++ args);
        try node.seal();
    }

    pub fn paragraph(self: *DocumentAuthor, text: []const u8) !void {
        const node = try self.tree.append(.block_paragraph);
        try StyledAuthor.createPlain(node, text);
    }

    pub fn paragraphFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.append(.block_paragraph);
        _ = try StyledAuthor.createPlainFmt(node, format, args);
    }

    pub fn paragraphStyled(self: *DocumentAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.tree.append(.block_paragraph) };
    }

    pub fn quote(self: *DocumentAuthor, text: []const u8) !void {
        const node = try self.tree.append(.block_quote);
        try StyledAuthor.createPlain(node, text);
    }

    pub fn quoteFmt(self: *DocumentAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.tree.append(.block_quote);
        _ = try StyledAuthor.createPlainFmt(node, format, args);
    }

    pub fn quoteStyled(self: *DocumentAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.tree.append(.block_quote) };
    }

    pub fn list(self: *DocumentAuthor, kind: ListKind) !ListAuthor {
        const node = try self.tree.append(.block_list);
        return ListAuthor{ .parent = node, .kind = kind };
    }

    pub fn table(self: *DocumentAuthor) !TableAuthor {
        return TableAuthor{ .node = try self.tree.append(.block_table) };
    }

    pub fn code(self: *DocumentAuthor, closure: zig.ContainerClosure) !void {
        try self.codeWith({}, closure);
    }

    pub fn codeWith(
        self: *DocumentAuthor,
        ctx: anytype,
        closure: Closure(@TypeOf(ctx), zig.ContainerClosure),
    ) !void {
        const data = try self.tree.allocator.create(zig.Container);
        errdefer self.tree.allocator.destroy(data);
        data.* = try zig.Container.init(self.allocator, ctx, closure);
        errdefer data.deinit(self.allocator);

        var node = try self.tree.append(.block_code);
        errdefer node.deinit();
        node.setPayload(std.mem.toBytes(@intFromPtr(data)));
        try node.seal();
    }
};

pub const ContainerAuthor = struct {
    parent: MarkTreeAuthor.Node,

    pub fn deinit(self: *StyledAuthor) void {
        self.parent.deinit();
    }

    pub fn seal(self: *StyledAuthor) !void {
        try self.parent.seal();
    }

    pub fn paragraph(self: *ContainerAuthor, text: []const u8) !void {
        const node = try self.parent.append(.block_paragraph);
        try StyledAuthor.createPlain(node, text);
    }

    pub fn paragraphFmt(self: *ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.parent.append(.block_paragraph);
        _ = try StyledAuthor.createPlainFmt(node, format, args);
    }

    pub fn paragraphStyled(self: *ContainerAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.parent.append(.block_paragraph) };
    }

    pub fn quote(self: *ContainerAuthor, text: []const u8) !void {
        const node = try self.parent.append(.block_quote);
        try StyledAuthor.createPlain(node, text);
    }

    pub fn quoteFmt(self: *ContainerAuthor, comptime format: []const u8, args: anytype) !void {
        const node = try self.parent.append(.block_quote);
        _ = try StyledAuthor.createPlainFmt(node, format, args);
    }

    pub fn quoteStyled(self: *ContainerAuthor) !StyledAuthor {
        return StyledAuthor{ .parent = try self.parent.append(.block_quote) };
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
        const data = try self.parent.allocator.create(zig.Container);
        errdefer self.parent.allocator.destroy(data);
        data.* = try zig.Container.init(self.allocator, ctx, closure);
        errdefer data.deinit(self.allocator);

        var node = try self.parent.append(.block_code);
        errdefer node.deinit();
        node.setPayload(std.mem.toBytes(@intFromPtr(data)));
        try node.seal();
    }
};

pub const StyledAuthor = struct {
    parent: MarkTreeAuthor.Node,
    callback: ?Callback = null,

    const CallbackFn = fn (
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

    fn createPlain(parent: MarkTreeAuthor.Node, text: []const u8) !void {
        errdefer parent.deinit();
        var child = try parent.append(.text_plain);
        errdefer child.deinit();
        child.setPayload(text);
        try child.seal();
        try parent.seal();
    }

    fn createPlainFmt(
        parent: MarkTreeAuthor.Node,
        comptime format: []const u8,
        args: anytype,
    ) !source_tree.Indexer {
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
        node.setPayload(text);
        try node.seal();

        if (self.callback) |cb| cb.increment(text.len);
    }

    pub fn plainFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_plain);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |cb| cb.increment(len);
    }

    pub fn italic(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_italic);
        errdefer node.deinit();
        node.setPayload(text);
        try node.seal();

        if (self.callback) |cb| cb.increment(2 + text.len);
    }

    pub fn italicFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_italic);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |cb| cb.increment(2 + len);
    }

    pub fn bold(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_bold);
        errdefer node.deinit();
        node.setPayload(text);
        try node.seal();

        if (self.callback) |cb| cb.increment(4 + text.len);
    }

    pub fn boldFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_bold);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |cb| cb.increment(4 + len);
    }

    pub fn boldItalic(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_bold_italic);
        errdefer node.deinit();
        node.setPayload(text);
        try node.seal();

        if (self.callback) |cb| cb.increment(6 + text.len);
    }

    pub fn boldItalicFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_bold_italic);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |cb| cb.increment(6 + len);
    }

    pub fn code(self: *StyledAuthor, text: []const u8) !void {
        var node = try self.parent.append(.text_code);
        errdefer node.deinit();
        node.setPayload(text);
        try node.seal();

        if (self.callback) |cb| cb.increment(2 + text.len);
    }

    pub fn codeFmt(self: *StyledAuthor, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_code);
        errdefer node.deinit();
        const len = try node.setPayloadFmt(format, args);
        try node.seal();

        if (self.callback) |cb| cb.increment(2 + len);
    }

    pub fn link(self: *StyledAuthor, href: []const u8, text: []const u8) !void {
        var node = try self.parent.append(.text_link);
        node.setPayload(href);
        try StyledAuthor.createPlain(node, text);

        if (self.callback) |cb| cb.increment(4 + href.len + text.len);
    }

    pub fn linkFmt(self: *StyledAuthor, href: []const u8, comptime format: []const u8, args: anytype) !void {
        var node = try self.parent.append(.text_link);
        node.setPayload(href);
        const len = try StyledAuthor.createPlainFmt(node, format, args);

        if (self.callback) |cb| cb.increment(4 + href.len + len);
    }

    pub fn linkStyled(self: *StyledAuthor, href: []const u8) !StyledAuthor {
        var node = try self.parent.append(.text_link);
        node.setPayload(href);

        if (self.callback) |cb| {
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

    fn increment(ctx: *anyopaque, _: usize, length: usize) void {
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
        self.parent.setPayload(&.{@intFromEnum(self.kind)});
        try self.parent.seal();
    }

    pub fn text(self: *ListAuthor, value: []const u8) !void {
        const child = try self.parent.append(.block_list_item);
        try StyledAuthor.createPlain(child, value);
    }

    pub fn textFmt(self: *ListAuthor, comptime format: []const u8, args: anytype) !void {
        const child = try self.parent.append(.block_list_item);
        _ = try StyledAuthor.createPlainFmt(child, format, args);
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
        self.parent.deinit();
    }

    pub fn seal(self: *TableAuthor) !void {
        const columns = self.columns.items;
        if (columns.len == 0) return error.EmptyTable;
        if (columns.len > MAX_TABLE_COLUMNS) return error.TooManyTableColumns;
        if (self.parent.children.items.len == columns.len) return error.EmptyTable;

        const payload = std.mem.sliceAsBytes(columns);
        self.parent.setPayload(payload);
        try self.parent.seal();
    }

    pub fn columnText(self: *TableAuthor, aligns: Table.Align, value: []const u8) !void {
        if (value.len > 255) return error.CellValueTooLong;
        if (!self.columns_sealed) return error.TableColumnAfterRows;

        try self.columns.append(self.parent.allocator, MarkColumn{
            .aligns = aligns,
            .self_width = @truncate(value.len),
            .dynamic_width = @truncate(value.len),
        });
        errdefer _ = self.columns.pop();

        const child = try self.parent.append(.block_table_column);
        try StyledAuthor.createPlain(child, value);
    }

    pub fn columnFmt(
        self: *TableAuthor,
        aligns: Table.Align,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (!self.columns_sealed) return error.TableColumnAfterRows;

        var child = try self.parent.append(.block_table_column);
        errdefer child.deinit();

        const len = try StyledAuthor.createPlainFmt(child, format, args);
        if (len > 255) return error.CellValueTooLong;

        try self.columns.append(self.parent.allocator, MarkColumn{
            .aligns = aligns,
            .self_width = @truncate(len),
            .dynamic_width = @truncate(len),
        });
    }

    pub fn columnStyled(self: *TableAuthor, aligns: Table.Align) !StyledAuthor {
        if (!self.columns_sealed) return error.TableColumnAfterRows;

        const column_index = self.columns.items.len;
        try self.columns.append(self.parent.allocator, MarkColumn{ .aligns = aligns, .dynamic_width = 0 });
        errdefer _ = self.columns.pop();

        return StyledAuthor{
            .parent = try self.parent.append(.block_table_column),
            .callback = .{
                .context = &self.columns,
                .index = column_index,
                .func = updateStyledColumnWidth,
            },
        };
    }

    fn updateStyledColumnWidth(ctx: *anyopaque, _: *MarkTreeAuthor.Node, index: usize, width: u8) !void {
        if (width > 255) return error.CellValueTooLong;
        const self: *std.ArrayListUnmanaged(MarkColumn) = @ptrCast(@alignCast(ctx));
        const column = &self.columns.items[index];
        if (width > column.dynamic_width) column.dynamic_width = @truncate(width);
    }

    pub fn rowText(self: *TableAuthor, cells: []const []const u8) !void {
        if (cells.len != self.columns.items.len) return error.RowColumnsMismatch;

        const row = try self.parent.append(.block_table_row);
        errdefer row.deinit();

        for (cells, 0..) |cell, i| {
            if (cell.len > 255) return error.CellValueTooLong;

            const child = try row.append(.block_table_cell);
            errdefer child.deinit();
            child.setPayload(&.{@truncate(cell.len)});
            try StyledAuthor.createPlain(child, cell);
            const column = &self.columns.items[i];
            if (cell.len > column.dynamic_width) column.dynamic_width = @truncate(cell.len);
        }

        try row.seal();
        self.columns_sealed = true;
    }

    pub fn rowContainer(self: *TableAuthor) !Row {
        const child = try self.parent.append(.block_table_row);
        self.columns_sealed = true;
        return Row{
            .parent = child,
            .columns = &self.columns,
        };
    }

    pub const Row = struct {
        parent: MarkTreeAuthor.Node,
        columns: *std.ArrayListUnmanaged(MarkColumn) = .{},

        pub fn deinit(self: *Row) void {
            self.parent.deinit();
        }

        pub fn seal(self: *Row) !void {
            try self.parent.seal();
        }

        pub fn cell(self: *Row, value: []const u8) !void {
            const column_index = self.parent.children.items.len;
            if (column_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const column = &self.columns.items[column_index];
            const child = try self.parent.append(.block_table_cell);
            child.setPayload(&.{@truncate(cell.len)});
            try StyledAuthor.createPlain(child, value);
            if (value.len > column.dynamic_width) column.dynamic_width = @truncate(value.len);
        }

        pub fn cellFmt(self: *Row, comptime format: []const u8, args: anytype) !void {
            const column_index = self.parent.children.items.len;
            if (column_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const column = &self.columns.items[column_index];
            const child = try self.parent.append(.block_table_cell);
            errdefer child.deinit();

            var text = try child.append(.text_plain);
            errdefer text.deinit();
            const width = try text.setPayloadFmt(format, args);
            if (width > column.dynamic_width) column.dynamic_width = @truncate(width);
            try text.seal();

            child.setPayload(&.{@truncate(width)});
            try child.seal();
        }

        pub fn cellStyled(self: *Row) !StyledAuthor {
            const column_index = self.parent.children.items.len;
            if (column_index >= self.columns.items.len) return error.RowColumnsMismatch;

            const child = try self.parent.append(.block_table_cell);
            return StyledAuthor{
                .parent = child,
                .callback = .{
                    .context = self.columns,
                    .index = column_index,
                    .func = updateStyledCellWidth,
                },
            };
        }

        fn updateStyledCellWidth(ctx: *anyopaque, node: *MarkTreeAuthor.Node, index: usize, width: u8) !void {
            node.setPayload(&.{@truncate(width)});
            try updateStyledColumnWidth(ctx, node, index, width);
        }
    };
};

test {
    _ = html;
}
