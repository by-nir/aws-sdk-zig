const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const md = @import("../md.zig");
const Writer = @import("../CodegenWriter.zig");

const log = std.log.scoped(.html_to_md);

pub const CallbackContext = struct {
    allocator: Allocator,
    html: []const u8,
};

pub fn callback(ctx: CallbackContext, b: *md.DocumentAuthor) !void {
    try convert(ctx.allocator, b, ctx.html);
}

const HtmlTag = enum(u32) {
    ROOT = 0,
    TEXT = std.math.maxInt(u32),
    p = hash("p"),
    ul = hash("ul"),
    ol = hash("ol"),
    li = hash("li"),
    a = hash("a"),
    b = hash("b"),
    strong = hash("strong"),
    i = hash("i"),
    em = hash("em"),
    code = hash("code"),
    _,

    pub fn parse(str: []const u8) HtmlTag {
        return @enumFromInt(hash(str));
    }

    fn hash(str: []const u8) u64 {
        std.debug.assert(str.len > 0 and str.len <= 32);
        var output: [32]u8 = undefined;
        const name = std.ascii.lowerString(&output, str);
        return std.hash.CityHash32.hash(name);
    }

    pub fn isInline(self: HtmlTag) bool {
        return switch (self) {
            .TEXT, .a, .b, .strong, .i, .em, .code => true,
            else => false,
        };
    }
};

const HtmlTagInfo = struct {
    raw: []const u8,
    tag: HtmlTag,
    kind: Kind,

    pub const Kind = enum { open, close, self_close };

    pub fn parse(raw: []const u8) HtmlTagInfo {
        std.debug.assert(raw.len > 2);
        std.debug.assert(raw[0] == '<' and raw[raw.len - 1] == '>');
        std.debug.assert(!mem.eql(u8, "</>", raw));

        const kind: Kind = if (raw[raw.len - 2] == '/')
            .self_close
        else if (raw[1] == '/')
            .close
        else
            .open;

        const tag = blk: {
            const start: usize = if (kind == .close) 2 else 1;
            const end: usize = if (kind == .self_close) raw.len - 2 else raw.len - 1;
            const name = if (mem.indexOfScalarPos(u8, raw, start, ' ')) |idx| raw[start..idx] else raw[start..end];
            break :blk HtmlTag.parse(name);
        };

        return .{
            .raw = raw,
            .tag = tag,
            .kind = kind,
        };
    }
};

test "HtmlTagInfo" {
    try testing.expectEqualDeep(HtmlTagInfo{ .raw = "<p>", .tag = .p, .kind = .open }, HtmlTagInfo.parse("<p>"));
    try testing.expectEqualDeep(HtmlTagInfo{ .raw = "</p>", .tag = .p, .kind = .close }, HtmlTagInfo.parse("</p>"));
    try testing.expectEqualDeep(HtmlTagInfo{ .raw = "<p />", .tag = .p, .kind = .self_close }, HtmlTagInfo.parse("<p />"));
}

/// Naively parse HTML source, normalize whitespace, and convert entities to unicode.
const HtmlFragmenter = struct {
    allocator: Allocator,
    token: []const u8 = "",
    stream: mem.TokenIterator(u8, .any),
    buffer: std.ArrayListUnmanaged(u8) = .{},

    pub const Fragment = union(enum) {
        tag: []const u8,
        text: []const u8,

        pub fn deinit(self: Fragment, allocator: Allocator) void {
            switch (self) {
                inline else => |s| allocator.free(s),
            }
        }
    };

    pub fn init(allocator: Allocator, html: []const u8) HtmlFragmenter {
        return .{
            .allocator = allocator,
            .stream = mem.tokenizeAny(u8, html, &std.ascii.whitespace),
        };
    }

    pub fn deinit(self: *HtmlFragmenter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn next(self: *HtmlFragmenter) !?Fragment {
        errdefer self.buffer.deinit(self.allocator);
        while (true) {
            const idx = mem.indexOfAny(u8, self.token, "<>") orelse {
                try self.appendToBuffer(self.token);
                if (self.stream.next()) |token| {
                    self.token = token;
                    continue;
                } else {
                    self.token = "";
                    break;
                }
            };

            if (self.token[idx] == '<') {
                // Tag opening
                try self.appendToBuffer(self.token[0..idx]);
                self.token = self.token[idx..self.token.len];

                // Has buffered text?
                if (self.buffer.items.len > 0) break;

                try self.appendToBuffer("<");
                self.token = self.token[1..self.token.len];
            } else {
                // Tag closing
                try self.appendToBuffer(self.token[0 .. idx + 1]);
                self.token = self.token[idx + 1 .. self.token.len];

                // If not a valid tag continue parsing as raw text
                const buffer = self.buffer.items;
                if (buffer.len == idx + 1 or buffer[0] != '<') continue;
                if (buffer.len > 2 and buffer[1] == '/' and buffer[buffer.len - 2] == '/') continue; // `</>`, `</···/>`

                // Valid tag
                const fragment = try self.buffer.toOwnedSlice(self.allocator);
                return Fragment{ .tag = fragment };
            }
        }

        const fragment = try self.buffer.toOwnedSlice(self.allocator);
        if (fragment.len > 0) {
            return Fragment{ .text = fragment };
        } else {
            return null;
        }
    }

    fn appendToBuffer(self: *HtmlFragmenter, text: []const u8) !void {
        if (text.len == 0) return;

        const buffer = self.buffer.items;
        const is_open_only = mem.eql(u8, buffer, "<");
        if (!is_open_only and (buffer.len > 0 or mem.startsWith(u8, text, "/>"))) {
            try self.buffer.append(self.allocator, ' ');
        }

        // TODO: convert entities to unicode https://html.spec.whatwg.org/entities.json
        try self.buffer.appendSlice(self.allocator, text);
    }

    fn expectNext(self: *HtmlFragmenter, expected: Fragment) !void {
        const frag = (try self.next()) orelse return error.FragmentsDepleted;
        defer frag.deinit(test_alloc);
        try testing.expectEqualDeep(expected, frag);
    }
};

test "HtmlFragmenter" {
    var frags = HtmlFragmenter.init(test_alloc, "foo bar<baz>qux</baz><foo /></invalid/></invalid /></>");
    errdefer frags.deinit();

    try frags.expectNext(.{ .text = "foo bar" });
    try frags.expectNext(.{ .tag = "<baz>" });
    try frags.expectNext(.{ .text = "qux" });
    try frags.expectNext(.{ .tag = "</baz>" });
    try frags.expectNext(.{ .tag = "<foo />" });
    try frags.expectNext(.{ .text = "</invalid/>" });
    try frags.expectNext(.{ .text = "</invalid />" });
    try frags.expectNext(.{ .text = "</>" });
    try testing.expectEqual(null, try frags.next());
}

const HtmlNode = struct {
    const Self = @This();

    tag: HtmlTag,
    raw: []const u8,
    children: std.ArrayListUnmanaged(*HtmlNode) = .{},

    pub fn init(allocator: Allocator, tag: HtmlTag, raw: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .tag = tag, .raw = raw };
        return self;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.children.items) |node| node.deinit(allocator);
        self.children.deinit(allocator);
        if (self.raw.len > 0) allocator.free(self.raw);
        allocator.destroy(self);
    }

    pub fn appendChild(self: *Self, allocator: Allocator, tag: HtmlTag, raw: []const u8) !*Self {
        const child = try init(allocator, tag, raw);
        errdefer child.deinit(allocator);
        try self.children.append(allocator, child);
        return child;
    }

    pub fn iterate(self: Self) Iterator {
        return .{ .children = self.children.items };
    }

    pub const Iterator = struct {
        index: usize = 0,
        children: []const *HtmlNode,

        pub fn next(self: *Iterator) ?*HtmlNode {
            if (self.index >= self.children.len) return null;
            defer self.index += 1;
            return self.children[self.index];
        }
    };
};

fn buildTree(allocator: Allocator, html: []const u8) !*HtmlNode {
    var frags = HtmlFragmenter.init(allocator, html);
    const meta = HtmlTagInfo{ .tag = .ROOT, .kind = .open, .raw = "" };
    const root = try HtmlNode.init(allocator, .ROOT, "");
    try buildNode(allocator, &frags, root, meta);
    return root;
}

fn buildNode(allocator: Allocator, frags: *HtmlFragmenter, node: *HtmlNode, meta: HtmlTagInfo) !void {
    while (try frags.next()) |frag| {
        switch (frag) {
            .text => |s| _ = try node.appendChild(allocator, .TEXT, s),
            .tag => |s| {
                const child_meta = HtmlTagInfo.parse(s);
                switch (child_meta.kind) {
                    .close => {
                        allocator.free(child_meta.raw);
                        return if (child_meta.tag == meta.tag) {} else error.UnexpectedClosingTag;
                    },
                    inline else => |g| {
                        errdefer allocator.free(child_meta.raw);
                        const child_node = try node.appendChild(allocator, child_meta.tag, child_meta.raw);
                        if (g == .open) try buildNode(allocator, frags, child_node, child_meta);
                    },
                }
            },
        }
    }
}

test "buildTree" {
    const tree = try buildTree(test_alloc, "foo<p /><ul><li /></ul>");
    defer tree.deinit(test_alloc);

    var it = tree.iterate();
    try testing.expectEqualDeep(&HtmlNode{ .tag = .TEXT, .raw = "foo" }, it.next().?);
    try testing.expectEqualDeep(&HtmlNode{ .tag = .p, .raw = "<p />" }, it.next().?);

    const list = it.next().?;
    try testing.expectEqual(HtmlTag.ul, list.tag);
    try testing.expectEqual(null, it.next());

    it = list.iterate();
    try testing.expectEqualDeep(&HtmlNode{ .tag = .li, .raw = "<li />" }, it.next().?);
    try testing.expectEqual(null, it.next());
}

/// Write Markdown source using an **extremely naive and partial** Markdown parser.
pub fn convert(allocator: Allocator, bld: *md.DocumentAuthor, html: []const u8) !void {
    const tree = try buildTree(allocator, html);
    errdefer tree.deinit(allocator);

    var it = tree.iterate();
    while (it.next()) |node| {
        try convertNode(.{ .document = bld }, node);
    }
}

const NodeBuilder = union(enum) {
    document: *md.DocumentAuthor,
    container: *md.ContainerAuthor,
};

fn convertNode(bld: NodeBuilder, node: *const HtmlNode) !void {
    switch (node.tag) {
        .TEXT => switch (bld) {
            inline else => |t| try t.paragraph(node.raw),
        },
        .p => {
            var paragraph: md.StyledAuthor = switch (bld) {
                inline else => |t| try t.paragraphStyled(),
            };
            errdefer paragraph.deinit();

            var it = node.iterate();
            while (it.next()) |child| {
                try convertStyledNode(&paragraph, child);
            }

            try paragraph.seal();
        },
        inline .ul, .ol => |tag| {
            const kind: md.ListKind = if (tag == .ul) .unordered else .ordered;
            var list: md.ListAuthor = switch (bld) {
                inline else => |t| try t.list(kind),
            };
            errdefer list.deinit();

            var it = node.iterate();
            while (it.next()) |child| {
                std.debug.assert(child.tag == .li);

                var container = try list.container();
                errdefer container.deinit();

                var styled: ?md.StyledAuthor = null;
                errdefer if (styled) |*t| t.deinit();

                var item_it = child.iterate();
                while (item_it.next()) |item| {
                    if (item.tag.isInline()) {
                        if (styled == null) styled = try container.paragraphStyled();
                        try convertStyledNode(&styled.?, item);
                    } else {
                        if (styled) |*t| {
                            defer styled = null;
                            try t.seal();
                        }

                        try convertNode(.{ .container = &container }, item);
                    }
                }

                if (styled) |*t| try t.seal();
            }
        },
        else => {
            // TODO: Custom tag handlers
            log.warn("Unrecognized tag: `<{}>`", .{node.tag});

            var it = node.iterate();
            while (it.next()) |child| {
                try convertNode(bld, child);
            }
        },
    }
}

fn convertStyledNode(bld: *md.StyledAuthor, node: *const HtmlNode) !void {
    switch (node.tag) {
        .TEXT => try bld.plain(node.raw),
        .b, .strong => {
            const text = TEMP_extractNodeText(node);
            try bld.bold(text);
        },
        .i, .em => {
            const text = TEMP_extractNodeText(node);
            try bld.italic(text);
        },
        .code => {
            const text = TEMP_extractNodeText(node);
            try bld.code(text);
        },
        .a => {
            const start = 6 + (mem.indexOf(u8, node.raw, "href=\"") orelse return error.MissingHrefAttribute);
            const end = mem.indexOfScalarPos(u8, node.raw, start, '"') orelse return error.MissingHrefAttribute;
            const href = node.raw[start..end];

            const text = TEMP_extractNodeText(node);
            try bld.link(href, null, text);
        },
        else => {
            // TODO: Custom tag handlers
            log.warn("Unrecognized tag: `<{}>`", .{node.tag});
        },
    }
}

// TODO: Support dynamic children
fn TEMP_extractNodeText(node: *const HtmlNode) []const u8 {
    std.debug.assert(node.children.items.len == 1);
    return node.children.items[0].raw;
}

test "convert" {
    try expect("<p>foo</p>", "foo");

    try expect("Foo.\n    <p>Bar baz\n    <qux.</p>",
        \\Foo.
        \\
        \\Bar baz <qux.
    );

    try expect(
        "<p>Inline: <a href=\"#\">foo\n    106</a>, <i>bar \n    107</i>, <b>baz \n    108</b>, <code>qux \n    109</code>.</p>",
        "Inline: [foo 106](#), _bar 107_, **baz 108**, `qux 109`.",
    );

    try expect("<ul>\n<li>\nFoo 106\n</li>\n<li><code>Bar\n107</code></li>\n<li><p>Baz 108</p></li></ul>",
        \\- Foo 106
        \\- `Bar 107`
        \\- Baz 108
    );

    try expect(
        \\<ul>
        \\    <li>
        \\        <p>Foo</p>
        \\        <p>Bar</p>
        \\    </li>
        \\    <li>Baz</li>
        \\</ul>
    ,
        \\- Foo
        \\
        \\    Bar
        \\- Baz
    );

    try expect(
        \\<ul>
        \\    <li>
        \\        <p>Foo</p>
        \\        <ul>
        \\            <li>Bar</li>
        \\            <li>Baz</li>
        \\        </ul>
        \\    </li>
        \\    <li>Qux</li>
        \\</ul>
    ,
        \\- Foo
        \\
        \\    - Bar
        \\    - Baz
        \\- Qux
    );
}

fn expect(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var doc = blk: {
        var build = try md.DocumentAuthor.init(arena_alloc);
        errdefer build.deinit();

        try convert(arena_alloc, &build, source);

        break :blk try build.consume(arena_alloc);
    };
    errdefer doc.deinit(arena_alloc);

    try Writer.expectValue(expected, doc);
}
