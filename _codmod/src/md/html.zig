//! HTML source with EXTREMELY partial spec support.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const md = @import("../md.zig");
const Writer = @import("../CodegenWriter.zig");
const srct = @import("../utils/tree.zig");

const log = std.log.scoped(.html_to_md);

pub const CallbackContext = struct {
    allocator: Allocator,
    html: []const u8,
    options: ParseOptions = .{},
};

pub fn callback(ctx: CallbackContext, b: md.ContainerAuthor) !void {
    try convert(ctx.allocator, b, ctx.html, ctx.options);
}

const HtmlTag = enum(u32) {
    document = 0,
    text = std.math.maxInt(u32),
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
        assert(str.len > 0 and str.len <= 32);
        var output: [32]u8 = undefined;
        const name = std.ascii.lowerString(&output, str);
        return std.hash.CityHash32.hash(name);
    }

    pub fn isInline(self: HtmlTag) bool {
        return switch (self) {
            .text, .a, .b, .strong, .i, .em, .code => true,
            else => false,
        };
    }

    pub fn isCustom(self: HtmlTag) bool {
        return std.enums.tagName(HtmlTag, self) == null;
    }
};

/// Naively parse HTML source, normalize whitespace, and convert entities to unicode.
const HtmlFragmenter = struct {
    token: []const u8 = "",
    scratch: std.ArrayList(u8),
    stream: mem.TokenIterator(u8, .any),
    codeblock: CodeblockState = .unsafe,

    pub const Fragment = union(enum) {
        tag: []const u8,
        text: []const u8,
    };

    const CodeblockState = enum { unsafe, safe, active };

    pub fn init(allocator: Allocator, html: []const u8) HtmlFragmenter {
        return .{
            .scratch = std.ArrayList(u8).init(allocator),
            .stream = mem.tokenizeAny(u8, html, &std.ascii.whitespace),
        };
    }

    /// When `true` the fragmenter will parse all content inside `<code>` tag as
    /// raw text, ignoring any HTML directives.
    ///
    /// Does not support nested `<code>` tags!
    pub fn initCodeblockSafe(allocator: Allocator, html: []const u8) HtmlFragmenter {
        return .{
            .scratch = std.ArrayList(u8).init(allocator),
            .stream = mem.tokenizeAny(u8, html, &std.ascii.whitespace),
            .codeblock = .safe,
        };
    }

    pub fn deinit(self: HtmlFragmenter) void {
        self.scratch.deinit();
    }

    /// The returned fragment is invalidated by the next call to `next`.
    pub fn next(self: *HtmlFragmenter) !?Fragment {
        self.scratch.clearRetainingCapacity();
        while (true) {
            if (self.codeblock == .active) {
                @branchHint(.unlikely);
                if (mem.indexOf(u8, self.token, "</code>")) |idx| {
                    try self.appendToScratch(self.token[0..idx]);
                    self.token = self.token[idx..self.token.len];
                    self.codeblock = .safe;
                    break;
                } else {
                    try self.appendToScratch(self.token);
                    if (self.stream.next()) |token| {
                        self.token = token;
                        continue;
                    } else {
                        self.token = "";
                        break;
                    }
                }
            }

            const idx = mem.indexOfAny(u8, self.token, "<>") orelse {
                try self.appendToScratch(self.token);
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
                try self.appendToScratch(self.token[0..idx]);
                self.token = self.token[idx..self.token.len];

                // Has buffered text?
                if (self.scratch.items.len > 0) break;

                try self.appendToScratch("<");
                self.token = self.token[1..self.token.len];
            } else {
                // Tag closing
                try self.appendToScratch(self.token[0 .. idx + 1]);
                self.token = self.token[idx + 1 .. self.token.len];

                // If not a valid tag continue parsing as raw text
                const scratch = self.scratch.items;
                if (scratch.len == idx + 1 or scratch[0] != '<') continue;
                if (scratch.len > 2 and scratch[1] == '/' and scratch[scratch.len - 2] == '/') continue; // `</>`, `</···/>`
                if (scratch.len > 2 and scratch[1] != '/' and !std.ascii.isAlphabetic(scratch[1])) continue; // `<=+->`

                // Codeblock?
                if (self.codeblock == .safe and std.mem.eql(u8, "<code>", scratch)) {
                    @branchHint(.unlikely);
                    self.codeblock = .active;
                }

                // Valid tag
                return Fragment{ .tag = scratch };
            }
        }

        const fragment = self.scratch.items;
        if (fragment.len > 0) {
            return Fragment{ .text = fragment };
        } else {
            return null;
        }
    }

    fn appendToScratch(self: *HtmlFragmenter, text: []const u8) !void {
        if (text.len == 0) return;

        const scratch = self.scratch.items;
        const is_open_only = mem.eql(u8, scratch, "<");
        if (!is_open_only and (scratch.len > 0 or mem.startsWith(u8, text, "/>"))) {
            try self.scratch.append(' ');
        }

        // TODO: convert entities to unicode https://html.spec.whatwg.org/entities.json
        try self.scratch.appendSlice(text);
    }
};

test "HtmlFragmenter" {
    var frags = HtmlFragmenter.init(
        test_alloc,
        "foo bar<baz>qux</baz><foo /></invalid/></invalid /></><=+-><img src=\"#\" />",
    );
    defer frags.deinit();

    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "foo bar" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "<baz>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "qux" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "</baz>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "<foo />" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "</invalid/>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "</invalid />" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "</>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "<=+->" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "<img src=\"#\" />" }, (try frags.next()).?);
    try testing.expectEqual(null, try frags.next());
    frags.deinit();

    // Codeblock safe option
    frags = HtmlFragmenter.initCodeblockSafe(test_alloc, "<foo><code><bar>baz</bar></code></foo>");
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "<foo>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "<code>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .text = "<bar>baz</bar>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "</code>" }, (try frags.next()).?);
    try testing.expectEqualDeep(HtmlFragmenter.Fragment{ .tag = "</foo>" }, (try frags.next()).?);
    try testing.expectEqual(null, try frags.next());
}

const TagMeta = struct {
    kind: Kind,
    tag: HtmlTag,
    attrs: ?[]const u8 = null,

    pub const Kind = enum { open, close, self_close };

    pub fn parse(raw: []const u8) TagMeta {
        assert(raw.len > 2 and raw[0] == '<' and raw[raw.len - 1] == '>');
        assert(!mem.eql(u8, "</>", raw));

        const kind: Kind = if (raw[raw.len - 2] == '/')
            .self_close
        else if (raw[1] == '/')
            .close
        else
            .open;

        const start: usize = if (kind == .close) 2 else 1;
        const end: usize = if (kind == .self_close) raw.len - 2 else raw.len - 1;
        const name = if (mem.indexOfAnyPos(u8, raw, start, &std.ascii.whitespace)) |idx| raw[start..idx] else raw[start..end];
        const attrs = if (start + name.len == end) "" else mem.trim(u8, raw[start + name.len + 1 .. end], &std.ascii.whitespace);

        return .{
            .kind = kind,
            .tag = HtmlTag.parse(name),
            .attrs = if (attrs.len > 0) attrs else null,
        };
    }
};

test "TagMeta" {
    try testing.expectEqualDeep(TagMeta{ .kind = .open, .tag = .p }, TagMeta.parse("<p>"));
    try testing.expectEqualDeep(TagMeta{ .kind = .close, .tag = .p }, TagMeta.parse("</p>"));
    try testing.expectEqualDeep(TagMeta{ .kind = .self_close, .tag = .p }, TagMeta.parse("<p />"));

    try testing.expectEqualDeep(TagMeta{
        .kind = .self_close,
        .tag = .p,
        .attrs = "style=\"foo\"",
    }, TagMeta.parse("<p style=\"foo\" />"));
}

pub const ParseOptions = struct {
    /// When `true` the fragmenter will parse all content inside `<code>` tag as
    /// raw text, ignoring any HTML directives.
    ///
    /// Does not support nested `<code>` tags!
    codeblock_safety: bool = false,
    /// When a custom tag has no closing tag, the parser will treat it as raw
    /// text instead of an HTML tag.
    custom_tag_safety: bool = false,
};

const HtmlTree = srct.MutableSourceTree(HtmlTag);

fn parse(mut_alloc: Allocator, html: []const u8, options: ParseOptions) !HtmlTree {
    var frags = switch (options.codeblock_safety) {
        true => HtmlFragmenter.initCodeblockSafe(mut_alloc, html),
        false => HtmlFragmenter.init(mut_alloc, html),
    };
    defer frags.deinit();

    var tree = try HtmlTree.init(mut_alloc, .document);
    errdefer tree.deinit();

    try parseNode(&frags, &tree, srct.ROOT, .document, options.custom_tag_safety);
    return tree;
}

threadlocal var flatten_to_tag: HtmlTag = undefined;

fn parseNode(
    frags: *HtmlFragmenter,
    tree: *HtmlTree,
    parent: srct.NodeHandle,
    parent_tag: HtmlTag,
    custom_safety: bool,
) !void {
    while (try frags.next()) |frag| {
        switch (frag) {
            .text => |payload| _ = try tree.appendNodePayload(parent, .text, []const u8, payload),
            .tag => |s| {
                const meta = TagMeta.parse(s);
                switch (meta.kind) {
                    .close => {
                        if (meta.tag == parent_tag) {
                            @branchHint(.likely);
                            return;
                        } else if (parent_tag.isCustom()) {
                            flatten_to_tag = meta.tag;
                            return error.FlattenToTag;
                        } else {
                            return error.UnexpectedClosingTag;
                        }
                    },
                    .self_close => _ = try appendHtmlNode(tree, parent, meta.tag, meta.attrs),
                    .open => {
                        const node = try appendHtmlNode(tree, parent, meta.tag, meta.attrs);
                        if (!custom_safety or !meta.tag.isCustom() or s.len > 128) {
                            @branchHint(.likely);
                            try parseNode(frags, tree, node, meta.tag, custom_safety);
                        } else {
                            // Cache the raw tag since `frag.next()` overrides the raw slice
                            var buffer: [128]u8 = undefined;
                            @memcpy(buffer[0..s.len], s);
                            const raw_tag = buffer[0..s.len];

                            parseNode(frags, tree, node, meta.tag, custom_safety) catch |err| {
                                if (err != error.FlattenToTag) return err;

                                // Append the node’s tag as raw text
                                _ = try tree.appendNodePayload(parent, .text, []const u8, raw_tag);

                                // Consume the node’s children
                                try tree.reparentNodeChildren(node, parent);
                                tree.dropNode(node);

                                if (parent_tag == flatten_to_tag) {
                                    // Flattening completed
                                    return;
                                } else {
                                    // Continue flattening
                                    return error.FlattenToTag;
                                }
                            };
                        }
                    },
                }
            },
        }
    }
}

fn appendHtmlNode(tree: *HtmlTree, parent: srct.NodeHandle, tag: HtmlTag, attrs: ?[]const u8) !srct.NodeHandle {
    if (attrs) |payload| {
        return tree.appendNodePayload(parent, tag, []const u8, payload);
    } else {
        return tree.appendNode(parent, tag);
    }
}

test "parse" {
    var html = try parse(test_alloc, "foo<p /><ul><li /></ul>", .{});
    const tree = html.view();
    defer html.deinit();

    var it = tree.iterateChildren(srct.ROOT);

    var node = it.next().?;
    try testing.expectEqual(.text, tree.tag(node));
    try testing.expectEqualStrings("foo", tree.payload(node, []const u8));

    try testing.expectEqual(.p, tree.tag(it.next().?));

    node = it.next().?;
    try testing.expectEqual(.ul, tree.tag(node));
    try testing.expectEqual(null, it.next());

    it = tree.iterateChildren(node);
    try testing.expectEqual(.li, tree.tag(it.next().?));
    try testing.expectEqual(null, it.next());
}

/// Write Markdown source using an **extremely naive and partial** Markdown parser.
pub fn convert(allocator: Allocator, bld: md.ContainerAuthor, html: []const u8, options: ParseOptions) !void {
    var tree = try parse(allocator, html, options);
    defer tree.deinit();

    const view = tree.view();
    var it = view.iterateChildren(srct.ROOT);
    while (it.next()) |node| {
        try convertNode(bld, view, node);
    }
}

fn convertNode(bld: md.ContainerAuthor, html: HtmlTree.Viewer, node: srct.NodeHandle) !void {
    switch (html.tag(node)) {
        .text => try bld.paragraph(html.payload(node, []const u8)),
        .p => {
            var paragraph: md.StyledAuthor = try bld.paragraphStyled();
            errdefer paragraph.deinit();

            var it = html.iterateChildren(node);
            while (it.next()) |child| {
                try convertStyledNode(&paragraph, html, child, html.tag(child));
            }

            try paragraph.seal();
        },
        inline .ul, .ol => |list_tag| {
            const kind: md.ListKind = if (list_tag == .ul) .unordered else .ordered;
            var list: md.ListAuthor = try bld.list(kind);
            errdefer list.deinit();

            var it = html.iterateChildren(node);
            while (it.next()) |child| {
                assert(.li == html.tag(child));

                var container = try list.container();
                errdefer container.deinit();

                var styled: ?md.StyledAuthor = null;
                errdefer if (styled) |*t| t.deinit();

                var item_it = html.iterateChildren(child);
                while (item_it.next()) |item| {
                    const item_tag = html.tag(item);
                    if (item_tag.isInline()) {
                        if (styled == null) styled = try container.paragraphStyled();
                        try convertStyledNode(&styled.?, html, item, item_tag);
                    } else {
                        if (styled) |*t| {
                            defer styled = null;
                            try t.seal();
                        }

                        try convertNode(container, html, item);
                    }
                }

                if (styled) |*t| try t.seal();
            }
        },
        .b, .strong, .i, .em, .code, .a => {
            var paragraph: md.StyledAuthor = try bld.paragraphStyled();
            errdefer paragraph.deinit();

            try convertStyledNode(&paragraph, html, node, html.tag(node));
            try paragraph.seal();
        },
        else => |g| {
            log.warn("Unrecognized tag: `<{}>`", .{g});

            var it = html.iterateChildren(node);
            while (it.next()) |child| {
                try convertNode(bld, html, child);
            }
        },
    }
}

fn convertStyledNode(bld: *md.StyledAuthor, html: HtmlTree.Viewer, node: srct.NodeHandle, tag: HtmlTag) !void {
    switch (tag) {
        .text => try bld.plain(html.payload(node, []const u8)),
        .b, .strong => {
            assert(html.countChildren(node) > 0);
            if (isPlainTextChildren(html, node)) {
                try bld.bold(html.payload(html.childAt(node, 0), []const u8));
            } else {
                var styled = try bld.boldStyled();
                try convertStyledParent(&styled, html, node);
            }
        },
        .i, .em => {
            assert(html.countChildren(node) > 0);
            if (isPlainTextChildren(html, node)) {
                try bld.italic(html.payload(html.childAt(node, 0), []const u8));
            } else {
                var styled = try bld.italicStyled();
                try convertStyledParent(&styled, html, node);
            }
        },
        .code => {
            assert(html.countChildren(node) > 0);
            if (isPlainTextChildren(html, node)) {
                try bld.code(html.payload(html.childAt(node, 0), []const u8));
            } else {
                var styled = try bld.boldStyled();
                try convertStyledParent(&styled, html, node);
            }
        },
        .a => {
            const href = if (html.payloadOrNull(node, []const u8)) |payload| blk: {
                const start = 6 + (mem.indexOf(u8, payload, "href=\"") orelse return error.MissingHrefAttribute);
                const end = mem.indexOfScalarPos(u8, payload, start, '"') orelse return error.MissingHrefAttribute;
                break :blk payload[start..end];
            } else "";

            assert(html.countChildren(node) > 0);
            if (isPlainTextChildren(html, node)) {
                try bld.link(href, null, html.payload(html.childAt(node, 0), []const u8));
            } else {
                var styled = try bld.linkStyled(href, null);
                try convertStyledParent(&styled, html, node);
            }
        },
        else => {
            log.warn("Unrecognized tag: `<{}>`", .{tag});
        },
    }
}

fn convertStyledParent(bld: *md.StyledAuthor, html: HtmlTree.Viewer, node: srct.NodeHandle) anyerror!void {
    var it = html.iterateChildren(node);
    while (it.next()) |child| {
        try convertStyledNode(bld, html, child, html.tag(child));
    }
}

fn isPlainTextChildren(html: HtmlTree.Viewer, node: srct.NodeHandle) bool {
    return html.countChildren(node) == 1 and html.tag(html.childAt(node, 0)) == .text;
}

test "convert" {
    try expectConvert("<p>foo</p>", "foo");

    try expectConvert("<strong>foo</strong>", "**foo**");

    try expectConvert("<code><foo>, <bar></code>", "`<foo>, <bar>`");

    try expectConvert("Foo.\n    <p>Bar baz\n    <qux.</p>",
        \\Foo.
        \\
        \\Bar baz <qux.
    );

    try expectConvert(
        "<p>Inline: <a href=\"#\">foo\n    106</a>, <i>bar \n    107</i>, <b>baz \n    108</b>, <code>qux \n    109</code>.</p>",
        "Inline: [foo 106](#), _bar 107_, **baz 108**, `qux 109`.",
    );

    try expectConvert("<ul>\n<li>\nFoo 106\n</li>\n<li><code>Bar\n107</code></li>\n<li><p>Baz 108</p></li></ul>",
        \\- Foo 106
        \\- `Bar 107`
        \\- Baz 108
    );

    try expectConvert("<p><a href=\"#\">foo <i>bar</i> baz</a></p>", "[foo _bar_ baz](#)");

    try expectConvert(
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

    try expectConvert(
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

    try expectConvert("<p>foo <QUX> bar <QUX> baz</p>", "foo <QUX> bar <QUX> baz");
}

fn expectConvert(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var doc = blk: {
        var build = try md.MutableDocument.init(arena_alloc);
        errdefer build.deinit();
        try convert(arena_alloc, build.root(), source, .{
            .codeblock_safety = true,
            .custom_tag_safety = true,
        });
        break :blk try build.toReadOnly(arena_alloc);
    };
    errdefer doc.deinit(arena_alloc);

    try Writer.expectValue(expected, doc);
}
