const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const rows = @import("rows.zig");
const cols = @import("columns.zig");
const iter = @import("iterate.zig");
const common = @import("common.zig");

pub const HieararchyOptions = struct {
    Indexer: type = common.DefaultIndexer,
    Tag: type = void,
    Payload: type = void,
    /// Store the parent of each node.
    inverse: bool = false,
};

pub fn HierarchyHooks(comptime Indexer: type) type {
    const Handle = common.Handle(Indexer);
    return struct {
        /// Does not invoke on deinit.
        onDropNode: ?*const fn (ctx: *anyopaque, handle: Handle) void = null,
    };
}

fn HierarchyNode(options: HieararchyOptions) type {
    const Handle = common.Handle(options.Indexer);
    return struct {
        tag: options.Tag,
        payload: options.Payload,
        children: Handle = .none,
        parent: if (options.inverse) Handle else void = if (options.inverse) .none else {},
    };
}

pub fn ReadOnlyHierarchy(options: HieararchyOptions) type {
    const Idx = options.Indexer;
    const Node = HierarchyNode(options);

    return struct {
        const Self = @This();
        pub const Handle = common.Handle(Idx);
        pub const Iterator = iter.Iterator(Handle, .{});
        pub const Query = HierarchyQuery(options);

        nodes: cols.ReadOnlyColumns(Node, .{ .Indexer = Idx }),
        adjacents: rows.ReadOnlyRows(Handle, .{ .Indexer = Idx }),

        pub fn author(allocator: Allocator) Author {
            return Author.init(allocator);
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.adjacents.deinit(allocator);
        }

        pub fn query(self: *const Self) Query {
            return .{
                .nodes = self.nodes.query(),
                .adjacents = self.adjacents.query(),
            };
        }

        pub const Author = struct {
            const Adjacents = rows.ReadOnlyRows(Handle, .{ .Indexer = Idx });

            allocator: Allocator,
            nodes: std.MultiArrayList(Node) = .{},
            adjacents: Adjacents.Author,

            pub fn init(allocator: Allocator) Author {
                return Author{
                    .allocator = allocator,
                    .adjacents = Adjacents.author(allocator),
                };
            }

            pub fn deinit(self: *Author) void {
                self.nodes.deinit(self.allocator);
                self.adjacents.deinit();
            }

            pub fn consume(self: *Author) !Self {
                return .{
                    .adjacents = try self.adjacents.consume(self.allocator),
                    .nodes = .{
                        .columns = self.nodes.toOwnedSlice(),
                    },
                };
            }

            pub fn appendNode(
                self: *Author,
                parent: if (options.inverse) Handle else void,
                tag: options.Tag,
                payload: options.Payload,
            ) !Handle {
                const handle: Handle = @enumFromInt(self.nodes.len);
                try self.nodes.append(self.allocator, .{
                    .tag = tag,
                    .payload = payload,
                    .parent = if (options.inverse) parent else {},
                });
                return handle;
            }

            pub fn setChildren(self: *Author, parent: Handle, children: []const Handle) !void {
                const nodes = self.nodes.slice();
                const row = &nodes.items(.children)[@intFromEnum(parent)];
                assert(row.* == .none);
                row.* = @enumFromInt(try self.adjacents.appendRow(children));
            }

            pub fn reserveChildren(self: *Author, parent: Handle, count: usize) !Adjacents.ReservedRow {
                const nodes = self.nodes.slice();
                const row = &nodes.items(.children)[@intFromEnum(parent)];
                assert(row.* == .none);

                const reserved = try self.adjacents.reserveRow(@intCast(count), .none);
                row.* = @enumFromInt(reserved.index);
                return reserved;
            }
        };
    };
}

test "ReadOnlyHierarchy" {
    const Tree = ReadOnlyHierarchy(.{ .Tag = u8 });
    const tree = blk: {
        var author = Tree.author(test_alloc);
        errdefer author.deinit();

        const root = try author.appendNode({}, 0, {});
        const node1 = try author.appendNode({}, 1, {});
        const node2 = try author.appendNode({}, 2, {});
        try author.setChildren(root, &.{ node1, node2 });

        const children = try author.reserveChildren(node2, 2);
        children.setItem(0, try author.appendNode({}, 21, {}));
        children.setItem(1, try author.appendNode({}, 22, {}));

        break :blk try author.consume();
    };
    defer tree.deinit(test_alloc);

    const root = Tree.Handle.of(0);
    try testing.expectEqual(2, tree.query().childCount(root));
    try testing.expectEqual(1, tree.query().orderOf(root, Tree.Handle.of(2)));
    try expectTags(u8, tree.query(), root, &.{ 1, 2 });

    try expectTags(u8, tree.query(), Tree.Handle.of(2), &.{ 21, 22 });
}

pub fn MutableHierarchy(options: HieararchyOptions, hooks: HierarchyHooks(options.Indexer)) type {
    const Tag = options.Tag;
    const Payload = options.Payload;
    const has_hooks = hooks.onDropNode != null;
    const Nodes = cols.MutableColumns(HierarchyNode(options), .{
        .Indexer = options.Indexer,
    });

    return struct {
        const Self = @This();
        pub const Handle = common.Handle(options.Indexer);
        pub const Iterator = iter.Iterator(Handle, .{});
        pub const Query = HierarchyQuery(options);
        const Adjacents = rows.MutableRows(Handle, .{ .Indexer = options.Indexer });

        nodes: Nodes = .{},
        adjacents: Adjacents = .{},
        hooks_ctx: if (has_hooks) *anyopaque else void = if (has_hooks) undefined else {},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.adjacents.deinit(allocator);
        }

        pub fn query(self: *const Self) Query {
            return .{
                .nodes = self.nodes.query(),
                .adjacents = self.adjacents.query(),
            };
        }

        // Mutate //////////////////////////////////////////////////////////////

        pub fn appendNode(
            self: *Self,
            allocator: Allocator,
            parent: Handle,
            tag: Tag,
            payload: Payload,
        ) !Handle {
            const child = try self.claimNodeHandle(allocator, tag, payload, if (options.inverse) parent else {});
            errdefer self.releaseNodeHandle(allocator, child);

            if (parent != .none) {
                const row = self.nodes.refField(@intFromEnum(parent), .children);
                switch (row.*) {
                    .none => row.* = try self.claimListHandle(allocator, &.{child}),
                    else => try self.adjacents.append(allocator, @intFromEnum(row.*), child),
                }
            }

            return child;
        }

        pub fn insertNode(
            self: *Self,
            allocator: Allocator,
            parent: Handle,
            i: options.Indexer,
            tag: Tag,
            payload: Payload,
        ) !Handle {
            assert(parent != .none);

            const child = try self.claimNodeHandle(allocator, tag, payload, if (options.inverse) parent else {});
            errdefer self.releaseNodeHandle(allocator, child);

            const row = self.nodes.refField(@intFromEnum(parent), .children);
            switch (row.*) {
                .none => row.* = try self.claimListHandle(allocator, &.{child}),
                else => try self.adjacents.insert(allocator, .ordered, @intFromEnum(row.*), i, child),
            }

            return child;
        }

        pub fn dropNode(
            self: *Self,
            allocator: Allocator,
            layout: common.Reorder,
            parent: if (options.inverse) void else Handle,
            node: Handle,
        ) void {
            assert(node != .none);
            const nid = @intFromEnum(node);
            const node_qry = self.nodes.query();
            const adjs_qry = self.adjacents.query();

            self.onWillDropNode(node);
            switch (node_qry.peekField(nid, .children)) {
                .none => {},
                else => |child_list| {
                    self.dropListChildren(allocator, node_qry, adjs_qry, child_list);
                    self.releaseListHandle(allocator, child_list);
                },
            }

            switch (if (options.inverse) node_qry.peekField(nid, .parent) else parent) {
                .none => {},
                else => |pid| {
                    const parent_list = self.nodes.refField(@intFromEnum(pid), .children);
                    const lid = @intFromEnum(parent_list.*);
                    assert(parent_list.* != .none);
                    switch (adjs_qry.count(lid)) {
                        0 => unreachable,
                        1 => {
                            self.releaseListHandle(allocator, parent_list.*);
                            parent_list.* = .none;
                        },
                        else => self.adjacents.drop(layout, lid, node),
                    }
                },
            }

            self.releaseNodeHandle(allocator, node);
        }

        pub fn dropChildren(self: *Self, allocator: Allocator, parent: Handle) void {
            assert(parent != .none);

            const list = self.nodes.refField(@intFromEnum(parent), .children);
            assert(list.* != .none);

            self.dropListChildren(allocator, self.nodes.query(), self.adjacents.query(), list.*);
            self.releaseListHandle(allocator, list.*);
            list.* = .none;
        }

        fn dropListChildren(
            self: *Self,
            allocator: Allocator,
            node_qry: Nodes.Query,
            adjs_qry: Adjacents.Query,
            row: Handle,
        ) void {
            var children = adjs_qry.iterate(@intFromEnum(row));
            while (children.next()) |child| {
                self.onWillDropNode(child);
                switch (node_qry.peekField(@intFromEnum(child), .children)) {
                    .none => {},
                    else => |child_row| self.dropListChildren(allocator, node_qry, adjs_qry, child_row),
                }

                self.releaseNodeHandle(allocator, child);
            }
        }

        fn claimNodeHandle(
            self: *Self,
            allocator: Allocator,
            tag: Tag,
            payload: Payload,
            parent: if (options.inverse) Handle else void,
        ) !Handle {
            return @enumFromInt(try self.nodes.claimItem(allocator, .{
                .tag = tag,
                .payload = payload,
                .parent = parent,
            }));
        }

        fn releaseNodeHandle(self: *Self, allocator: Allocator, node: Handle) void {
            self.nodes.releaseItem(allocator, @intFromEnum(node));
        }

        fn onWillDropNode(self: Self, node: Handle) void {
            if (hooks.onDropNode) |hook| hook(self.hooks_ctx, node);
        }

        fn claimListHandle(self: *Self, allocator: Allocator, items: ?[]const Handle) !Handle {
            if (items) |slice| {
                return @enumFromInt(try self.adjacents.claimRowWithSlice(allocator, slice));
            } else {
                return @enumFromInt(try self.adjacents.claimRow(allocator));
            }
        }

        fn releaseListHandle(self: *Self, allocator: Allocator, list: Handle) void {
            self.adjacents.releaseRow(allocator, @intFromEnum(list));
        }

        pub fn setTag(self: *Self, node: Handle, tag: Tag) void {
            comptime assert(Tag != void);
            assert(node != .none);

            self.nodes.setField(@intFromEnum(node), .tag, tag);
        }

        pub fn refTag(self: *Self, node: Handle) *Tag {
            comptime assert(Tag != void);
            assert(node != .none);

            return self.nodes.refField(@intFromEnum(node), .tag);
        }

        pub fn setPayload(self: *Self, node: Handle, payload: Payload) void {
            comptime assert(Payload != void);
            assert(node != .none);

            self.nodes.setField(@intFromEnum(node), .payload, payload);
        }

        pub fn refPayload(self: *Self, node: Handle) *Payload {
            comptime assert(Payload != void);
            assert(node != .none);

            return self.nodes.refField(@intFromEnum(node), .payload);
        }
    };
}

fn expectTags(comptime G: type, query: anytype, parent: anytype, tags: []const G) !void {
    var it = query.iterateChildren(parent);
    try testing.expectEqual(tags.len, it.length());

    for (tags) |tag| try testing.expectEqual(tag, query.getTag(it.next().?));
    try testing.expectEqual(null, it.next());
}

test "MutableHierarchy" {
    const Author = MutableHierarchy(.{ .Tag = u8 }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const root = try author.appendNode(test_alloc, .none, 0, {});
    try testing.expectEqual(0, author.query().childCount(root));
    try testing.expectEqual(null, author.query().childAtOrNull(root, 0));

    var node1 = try author.appendNode(test_alloc, root, 1, {});
    try testing.expectEqual(1, author.query().childCount(root));
    try testing.expectEqual(0, author.query().orderOf(root, node1));
    try testing.expectEqual(node1, author.query().childAt(root, 0));
    try testing.expectEqualDeep(node1, author.query().childAtOrNull(root, 0));

    const node2 = try author.appendNode(test_alloc, root, 2, {});
    try testing.expectEqual(2, author.query().childCount(root));
    try testing.expectEqual(1, author.query().orderOf(root, node2));
    try testing.expectEqual(node2, author.query().childAt(root, 1));
    try expectTags(u8, author.query(), root, &.{ 1, 2 });

    author.dropNode(test_alloc, .ordered, root, node1);
    try testing.expectEqual(1, author.query().childCount(root));

    node1 = try author.insertNode(test_alloc, root, 0, 1, {});
    try testing.expectEqual(2, author.query().childCount(root));
    try testing.expectEqual(0, author.query().orderOf(root, node1));
    try testing.expectEqual(node1, author.query().childAt(root, 0));
    try testing.expectEqual(node2, author.query().childAt(root, 1));
    try expectTags(u8, author.query(), root, &.{ 1, 2 });

    try testing.expectEqual(0, author.query().childCount(node2));

    var node21 = try author.appendNode(test_alloc, node2, 21, {});
    try testing.expectEqual(1, author.query().childCount(node2));
    try testing.expectEqual(0, author.query().orderOf(node2, node21));

    const node22 = try author.appendNode(test_alloc, node2, 22, {});
    try testing.expectEqual(2, author.query().childCount(node2));
    try testing.expectEqual(1, author.query().orderOf(node2, node22));
    try expectTags(u8, author.query(), node2, &.{ 21, 22 });

    author.dropNode(test_alloc, .ordered, node2, node21);
    try testing.expectEqual(1, author.query().childCount(node2));

    node21 = try author.insertNode(test_alloc, node2, 0, 21, {});
    try testing.expectEqual(2, author.query().childCount(node2));
    try testing.expectEqual(0, author.query().orderOf(node2, node21));
    try expectTags(u8, author.query(), node2, &.{ 21, 22 });

    author.dropNode(test_alloc, .ordered, root, node2);
    try testing.expectEqual(1, author.query().childCount(root));

    const node11 = try author.appendNode(test_alloc, node1, 11, {});
    _ = try author.appendNode(test_alloc, node1, 12, {});
    try testing.expectEqual(2, author.query().childCount(node1));

    _ = try author.appendNode(test_alloc, node11, 111, {});

    author.dropChildren(test_alloc, node1);
    try testing.expectEqual(0, author.query().childCount(node1));

    author.dropChildren(test_alloc, root);
    try testing.expectEqual(0, author.query().childCount(root));
}

test "MutableHierarchy: inverse" {
    const Author = MutableHierarchy(.{
        .Tag = u8,
        .inverse = true,
    }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const root = try author.appendNode(test_alloc, .none, 0, {});
    try testing.expectEqual(0, author.query().childCount(root));

    const node1 = try author.appendNode(test_alloc, root, 1, {});
    try testing.expectEqual(1, author.query().childCount(root));
    try testing.expectEqual(0, author.query().orderOf({}, node1));

    const node2 = try author.insertNode(test_alloc, root, 0, 2, {});
    try testing.expectEqual(2, author.query().childCount(root));
    try testing.expectEqual(0, author.query().orderOf({}, node2));
    try expectTags(u8, author.query(), root, &.{ 2, 1 });
}

test "MutableHierarchy: paylod" {
    const Author = MutableHierarchy(.{ .Payload = u8 }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const node1 = try author.appendNode(test_alloc, .none, {}, 1);
    try testing.expectEqual(1, author.query().getPayload(node1));

    const node2 = try author.appendNode(test_alloc, .none, {}, 2);
    try testing.expectEqual(2, author.query().getPayload(node2));
    author.dropNode(test_alloc, .ordered, .none, node2);

    author.setPayload(node1, 18);
    try testing.expectEqual(18, author.query().getPayload(node1));

    const ref = author.refPayload(node1);
    try testing.expectEqual(18, ref.*);
    ref.* = 8;
    try testing.expectEqual(8, author.query().getPayload(node1));
}

test "MutableHierarchy: hooks" {
    const Handle = common.Handle(common.DefaultIndexer);
    const Test = struct {
        var count: u8 = 0;
        var nodes: [8]Handle = undefined;

        fn onWillDropNode(ctx: *anyopaque, node: Handle) void {
            const cnt: *u8 = @ptrCast(@alignCast(ctx));
            assert(cnt.* < 8);
            nodes[cnt.*] = node;
            cnt.* += 1;
        }
    };

    const Author = MutableHierarchy(.{}, .{
        .onDropNode = Test.onWillDropNode,
    });
    var author = Author{
        .hooks_ctx = &Test.count,
    };
    defer author.deinit(test_alloc);

    Test.count = 0;
    var node1 = try author.appendNode(test_alloc, .none, {}, {});
    author.dropNode(test_alloc, .ordered, .none, node1);
    try testing.expectEqual(1, Test.count);
    try testing.expectEqual(node1, Test.nodes[0]);

    Test.count = 0;
    node1 = try author.appendNode(test_alloc, .none, {}, {});
    const node2 = try author.appendNode(test_alloc, node1, {}, {});
    author.dropNode(test_alloc, .ordered, .none, node1);
    try testing.expectEqual(2, Test.count);
    try testing.expectEqual(node1, Test.nodes[0]);
    try testing.expectEqual(node2, Test.nodes[1]);
}

pub fn HierarchyQuery(comptime options: HieararchyOptions) type {
    const Handle = common.Handle(options.Indexer);
    const Iterator = iter.Iterator(Handle, .{});

    return struct {
        const Self = @This();

        nodes: cols.ColumnsQuery(options.Indexer, HierarchyNode(options)),
        adjacents: rows.RowsQuery(options.Indexer, Handle),

        pub fn getTag(self: Self, node: Handle) options.Tag {
            comptime assert(options.Tag != void);
            assert(node != .none);
            return self.nodes.peekField(@intFromEnum(node), .tag);
        }

        pub fn getPayload(self: Self, node: Handle) options.Payload {
            comptime assert(options.Payload != void);
            assert(node != .none);
            return self.nodes.peekField(@intFromEnum(node), .payload);
        }

        pub fn orderOf(self: Self, parent: if (options.inverse) void else Handle, child: Handle) options.Indexer {
            assert(child != .none);

            const pid = if (options.inverse) self.nodes.peekField(@intFromEnum(child), .parent) else parent;
            assert(pid != Handle.none);

            const list = self.nodes.peekField(@intFromEnum(pid), .children);
            assert(list != .none);

            return self.adjacents.orderOf(@intFromEnum(list), child);
        }

        pub fn childAt(self: Self, parent: Handle, i: usize) Handle {
            assert(parent != .none);
            const list = self.nodes.peekField(@intFromEnum(parent), .children);
            assert(list != .none);
            return self.adjacents.peekAt(@intFromEnum(list), @intCast(i));
        }

        pub fn childAtOrNull(self: Self, parent: Handle, i: usize) ?Handle {
            assert(parent != .none);
            const list = self.nodes.peekField(@intFromEnum(parent), .children);
            return switch (list) {
                .none => null,
                else => self.adjacents.peekAtOrNull(@intFromEnum(list), @intCast(i)),
            };
        }

        pub fn childCount(self: Self, parent: Handle) options.Indexer {
            assert(parent != .none);
            return switch (self.nodes.peekField(@intFromEnum(parent), .children)) {
                .none => 0,
                else => |list| self.adjacents.count(@intFromEnum(list)),
            };
        }

        pub fn iterateChildren(self: Self, parent: Handle) Iterator {
            assert(parent != .none);
            return switch (self.nodes.peekField(@intFromEnum(parent), .children)) {
                .none => .{ .items = &.{} },
                else => |list| self.adjacents.iterate(@intFromEnum(list)),
            };
        }
    };
}
