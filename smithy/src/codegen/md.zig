const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const test_alloc = std.testing.allocator;
const dcl = @import("../utils/declarative.zig");
const StackChain = dcl.StackChain;
const InferCallback = dcl.InferCallback;
const Cb = dcl.Callback;
const createCallback = dcl.callback;
const Closure = dcl.Closure;
const callClosure = dcl.callClosure;
const zig = @import("zig.zig");
const Writer = @import("CodegenWriter.zig");

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
            assert(segment.text.len > 0);
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
        assert(self.level > 0 and self.level <= 3);
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
        assert(self.items.len > 0);
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
            assert(self.items.items.len > 0); // First item can’t be a sub-list
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

        assert(self.rows.len > 0);
        assert(self.columns.len > 0);

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
            assert(name.len <= 255);
            assert(self.rows.items.len == 0);
            try self.columns.append(self.allocator, .{
                .name = name,
                .width = @truncate(name.len),
                .alignment = alignment,
            });
        }

        pub fn row(self: *Build, cells: []const []const u8) !void {
            assert(cells.len == self.columns.items.len);
            const alloc_cells = try self.allocator.dupe([]const u8, cells);
            errdefer self.allocator.free(alloc_cells);
            try self.rows.append(self.allocator, .{ .cells = alloc_cells });

            for (cells, 0..) |cell, i| {
                assert(cell.len <= 255);
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

test {
    _ = html;
}
