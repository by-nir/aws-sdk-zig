const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const rows = @import("rows.zig");
const cols = @import("columns.zig");
const iter = @import("../interface/iterate.zig");
const common = @import("../interface/common.zig");

pub const HierarchyOptions = struct {
    Indexer: type = common.DefaultIndexer,
    Tag: type = void,
    Payload: type = void,
    /// Store the parent of each node.
    inverse: bool = false,
    ordered: bool = true,
};

pub fn HierarchyHooks(comptime Indexer: type) type {
    const Handle = common.Handle(Indexer);
    return struct {
        /// Does not invoke on deinit.
        onDropNode: ?*const fn (ctx: *anyopaque, handle: Handle) void = null,
    };
}

fn HierarchyNode(options: HierarchyOptions) type {
    const Handle = common.Handle(options.Indexer);
    return struct {
        tag: options.Tag,
        payload: options.Payload,
        children: Handle = .none,
        parent: if (options.inverse) Handle else void = if (options.inverse) .none else {},
    };
}

pub fn Hierarchy(options: HierarchyOptions) type {
    const Idx = options.Indexer;
    const Node = HierarchyNode(options);

    return struct {
        const Self = @This();
        pub const Handle = common.Handle(Idx);
        pub const Viewer = HierarchyViewer(options);
        pub const Iterator = iter.Iterator(Handle, .{});

        nodes: cols.Columns(Node, .{ .Indexer = Idx }),
        adjacents: rows.Rows(Handle, .{ .Indexer = Idx }),

        pub fn author(allocator: Allocator) Author {
            return Author.init(allocator);
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.adjacents.deinit(allocator);
        }

        pub fn view(self: *const Self) Viewer {
            return .{
                .nodes = self.nodes.view(),
                .adjacents = self.adjacents.view(),
            };
        }

        pub const Author = struct {
            const Adjacents = rows.Rows(Handle, .{ .Indexer = Idx });

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

            /// The caller owns the returned memory.
            pub fn consume(self: *Author) !Self {
                return .{
                    .adjacents = try self.adjacents.consume(self.allocator),
                    .nodes = .{ .columns = self.nodes.toOwnedSlice() },
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

test "Hierarchy" {
    const Tree = Hierarchy(.{ .Tag = u8 });
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
    try testing.expectEqual(2, tree.view().countChildren(root));
    try testing.expectEqual(1, tree.view().findChild(root, Tree.Handle.of(2)));
    try expectChildrenTags(u8, tree.view(), root, &.{ 1, 2 });

    try expectChildrenTags(u8, tree.view(), Tree.Handle.of(2), &.{ 21, 22 });
}

pub fn MutableHierarchy(options: HierarchyOptions, hooks: HierarchyHooks(options.Indexer)) type {
    const Tag = options.Tag;
    const Payload = options.Payload;
    const has_hooks = hooks.onDropNode != null;
    const Nodes = cols.MutableColumns(HierarchyNode(options), .{
        .Indexer = options.Indexer,
    });
    const ordering: common.Reorder = if (options.ordered) .ordered else .swap;

    return struct {
        const Self = @This();
        pub const Handle = common.Handle(options.Indexer);
        pub const Viewer = HierarchyViewer(options);
        pub const Iterator = iter.Iterator(Handle, .{});
        const Edges = rows.MutableRows(Handle, .{ .Indexer = options.Indexer });

        nodes: Nodes = .{},
        edges: Edges = .{},
        hooks_ctx: if (has_hooks) *anyopaque else void = if (has_hooks) undefined else {},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.nodes.deinit(allocator);
            self.edges.deinit(allocator);
        }

        pub fn view(self: *const Self) Viewer {
            return .{
                .nodes = self.nodes.view(),
                .adjacents = self.edges.view(),
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

            if (parent != .none) try self.createOrAppendToList(allocator, parent, child);
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
                .none => {
                    assert(i == 0);
                    row.* = try self.claimListHandle(allocator, &.{child});
                },
                else => try self.edges.insert(allocator, ordering, @intFromEnum(row.*), i, child),
            }

            return child;
        }

        pub fn reparentNode(
            self: *Self,
            allocator: Allocator,
            node: Handle,
            old_parent: if (options.inverse) void else Handle,
            new_parent: Handle,
        ) !void {
            assert(node != .none);

            const parent_ref = if (options.inverse) self.nodes.refField(@intFromEnum(node), .parent) else {};
            const parent = if (options.inverse) parent_ref.* else old_parent;
            if (parent == new_parent) return;

            var success = false;
            defer {
                if (options.inverse and success) parent_ref.* = new_parent;
            }

            if (new_parent != .none) try self.createOrAppendToList(allocator, new_parent, node);
            if (parent != .none) self.deleteOrRemoveFromList(allocator, parent, node);
            success = true;
        }

        pub fn reparentChildren(self: *Self, allocator: Allocator, source: Handle, target: Handle) !void {
            assert(source != .none);
            const adjs_view = self.edges.view();

            const source_lid = self.nodes.refField(@intFromEnum(source), .children);
            if (source_lid.* == .none) return;

            // Do not access `children` after releasing `source_lid`!
            const children = adjs_view.allItems(@intFromEnum(source_lid.*));
            if (children.len == 0) return;

            var release_source = false;
            switch (target) {
                .none => release_source = true,
                else => {
                    const target_lid = self.nodes.refField(@intFromEnum(target), .children);
                    if (target_lid.* == .none) {
                        target_lid.* = source_lid.*;
                    } else if (adjs_view.countItems(@intFromEnum(target_lid.*)) == 0) {
                        self.releaseListHandle(allocator, target_lid.*);
                        target_lid.* = source_lid.*;
                    } else {
                        try self.edges.appendSlice(allocator, @intFromEnum(target_lid.*), children);
                        release_source = true;
                    }
                },
            }

            if (options.inverse) {
                for (children) |child| {
                    self.nodes.setField(@intFromEnum(child), .parent, target);
                }
            }

            if (release_source) self.releaseListHandle(allocator, source_lid.*);
            source_lid.* = .none;
        }

        pub fn dropNode(
            self: *Self,
            allocator: Allocator,
            parent: if (options.inverse) void else Handle,
            node: Handle,
        ) void {
            assert(node != .none);
            const nid = @intFromEnum(node);
            const node_view = self.nodes.view();
            const adjs_view = self.edges.view();

            self.onWillDropNode(node);
            switch (node_view.peekField(nid, .children)) {
                .none => {},
                else => |child_list| {
                    self.dropListChildren(allocator, node_view, adjs_view, child_list);
                    self.releaseListHandle(allocator, child_list);
                },
            }

            const pid = if (options.inverse) node_view.peekField(nid, .parent) else parent;
            if (pid != .none) self.deleteOrRemoveFromList(allocator, pid, node);
            self.releaseNodeHandle(allocator, node);
        }

        pub fn dropChildren(self: *Self, allocator: Allocator, parent: Handle) void {
            assert(parent != .none);

            const list = self.nodes.refField(@intFromEnum(parent), .children);
            if (list.* == .none) return;

            self.dropListChildren(allocator, self.nodes.view(), self.edges.view(), list.*);
            self.releaseListHandle(allocator, list.*);
            list.* = .none;
        }

        fn dropListChildren(
            self: *Self,
            allocator: Allocator,
            node_qry: Nodes.Viewer,
            adjs_qry: Edges.Viewer,
            row: Handle,
        ) void {
            assert(row != .none);
            var children = adjs_qry.iterateItems(@intFromEnum(row));
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

        fn createOrAppendToList(self: *Self, allocator: Allocator, parent_node: Handle, child: Handle) !void {
            assert(child != .none);
            assert(parent_node != .none);
            const list = self.nodes.refField(@intFromEnum(parent_node), .children);
            switch (list.*) {
                .none => list.* = try self.claimListHandle(allocator, &.{child}),
                else => try self.edges.append(allocator, @intFromEnum(list.*), child),
            }
        }

        /// Asserts the parent contains the child node.
        fn deleteOrRemoveFromList(self: *Self, allocator: Allocator, parent_node: Handle, child: Handle) void {
            assert(child != .none);
            assert(parent_node != .none);
            const list = self.nodes.refField(@intFromEnum(parent_node), .children);
            assert(list.* != .none);
            switch (self.edges.view().countItems(@intFromEnum(list.*))) {
                0 => unreachable,
                1 => {
                    self.releaseListHandle(allocator, list.*);
                    list.* = .none;
                },
                else => self.edges.drop(ordering, @intFromEnum(list.*), child),
            }
        }

        fn claimListHandle(self: *Self, allocator: Allocator, items: ?[]const Handle) !Handle {
            if (items) |slice| {
                return @enumFromInt(try self.edges.claimRowWithSlice(allocator, slice));
            } else {
                return @enumFromInt(try self.edges.claimRow(allocator));
            }
        }

        fn releaseListHandle(self: *Self, allocator: Allocator, list: Handle) void {
            self.edges.releaseRow(allocator, @intFromEnum(list));
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

fn expectChildrenTags(comptime G: type, view: anytype, parent: anytype, tags: []const G) !void {
    var it = view.iterateChildren(parent);
    try testing.expectEqual(tags.len, it.length());

    for (tags) |tag| try testing.expectEqual(tag, view.tag(it.next().?));
    try testing.expectEqual(null, it.next());
}

test "MutableHierarchy" {
    const Author = MutableHierarchy(.{ .Tag = u8 }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const root = try author.appendNode(test_alloc, .none, 0, {});
    try testing.expectEqual(0, author.view().countChildren(root));
    try testing.expectEqual(null, author.view().childAtOrNull(root, 0));

    var node1 = try author.appendNode(test_alloc, root, 1, {});
    try testing.expectEqual(1, author.view().countChildren(root));
    try testing.expectEqual(0, author.view().findChild(root, node1));
    try testing.expectEqual(node1, author.view().childAt(root, 0));
    try testing.expectEqualDeep(node1, author.view().childAtOrNull(root, 0));

    const node2 = try author.appendNode(test_alloc, root, 2, {});
    try testing.expectEqual(2, author.view().countChildren(root));
    try testing.expectEqual(1, author.view().findChild(root, node2));
    try testing.expectEqual(node2, author.view().childAt(root, 1));
    try expectChildrenTags(u8, author.view(), root, &.{ 1, 2 });

    author.dropNode(test_alloc, root, node1);
    try testing.expectEqual(1, author.view().countChildren(root));

    node1 = try author.insertNode(test_alloc, root, 0, 1, {});
    try testing.expectEqual(2, author.view().countChildren(root));
    try testing.expectEqual(0, author.view().findChild(root, node1));
    try testing.expectEqual(node1, author.view().childAt(root, 0));
    try testing.expectEqual(node2, author.view().childAt(root, 1));
    try expectChildrenTags(u8, author.view(), root, &.{ 1, 2 });

    try testing.expectEqual(0, author.view().countChildren(node2));

    var node21 = try author.appendNode(test_alloc, node2, 21, {});
    try testing.expectEqual(1, author.view().countChildren(node2));
    try testing.expectEqual(0, author.view().findChild(node2, node21));

    const node22 = try author.appendNode(test_alloc, node2, 22, {});
    try testing.expectEqual(2, author.view().countChildren(node2));
    try testing.expectEqual(1, author.view().findChild(node2, node22));
    try expectChildrenTags(u8, author.view(), node2, &.{ 21, 22 });

    author.dropNode(test_alloc, node2, node21);
    try testing.expectEqual(1, author.view().countChildren(node2));

    node21 = try author.insertNode(test_alloc, node2, 0, 21, {});
    try testing.expectEqual(2, author.view().countChildren(node2));
    try testing.expectEqual(0, author.view().findChild(node2, node21));
    try expectChildrenTags(u8, author.view(), node2, &.{ 21, 22 });

    author.dropNode(test_alloc, root, node2);
    try testing.expectEqual(1, author.view().countChildren(root));

    const node11 = try author.appendNode(test_alloc, node1, 11, {});
    _ = try author.appendNode(test_alloc, node1, 12, {});
    try testing.expectEqual(2, author.view().countChildren(node1));

    _ = try author.appendNode(test_alloc, node11, 111, {});

    author.dropChildren(test_alloc, node1);
    try testing.expectEqual(0, author.view().countChildren(node1));

    author.dropChildren(test_alloc, root);
    try testing.expectEqual(0, author.view().countChildren(root));
}

test "MutableHierarchy: reparent" {
    const Author = MutableHierarchy(.{ .Tag = u8 }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const root = try author.appendNode(test_alloc, .none, 0, {});
    const node1 = try author.appendNode(test_alloc, root, 1, {});
    _ = try author.appendNode(test_alloc, node1, 11, {});
    try testing.expectEqual(1, author.view().countChildren(node1));

    const node2 = try author.appendNode(test_alloc, root, 2, {});
    try testing.expectEqual(0, author.view().countChildren(node2));

    const child = try author.appendNode(test_alloc, node2, 99, {});
    try testing.expectEqual(1, author.view().countChildren(node2));

    try author.reparentNode(test_alloc, child, node2, node1);
    try testing.expectEqual(0, author.view().countChildren(node2));
    try expectChildrenTags(u8, author.view(), node1, &.{ 11, 99 });

    try author.reparentChildren(test_alloc, node1, node2);
    try testing.expectEqual(0, author.view().countChildren(node1));
    try expectChildrenTags(u8, author.view(), node2, &.{ 11, 99 });
}

test "MutableHierarchy: inverse" {
    const Author = MutableHierarchy(.{
        .Tag = u8,
        .inverse = true,
    }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const root = try author.appendNode(test_alloc, .none, 0, {});
    try testing.expectEqual(0, author.view().countChildren(root));

    const node1 = try author.appendNode(test_alloc, root, 1, {});
    try testing.expectEqual(1, author.view().countChildren(root));
    try testing.expectEqual(0, author.view().findChild({}, node1));

    const node2 = try author.insertNode(test_alloc, root, 0, 2, {});
    try testing.expectEqual(2, author.view().countChildren(root));
    try testing.expectEqual(0, author.view().findChild({}, node2));
    try expectChildrenTags(u8, author.view(), root, &.{ 2, 1 });

    _ = try author.appendNode(test_alloc, node1, 11, {});
    _ = try author.appendNode(test_alloc, node2, 21, {});
    const child = try author.appendNode(test_alloc, node2, 99, {});
    try testing.expectEqual(1, author.view().countChildren(node1));
    try testing.expectEqual(2, author.view().countChildren(node2));
    try author.reparentNode(test_alloc, child, {}, node1);
    try testing.expectEqual(1, author.view().countChildren(node2));
    try expectChildrenTags(u8, author.view(), node1, &.{ 11, 99 });

    try author.reparentChildren(test_alloc, node1, node2);
    try testing.expectEqual(0, author.view().countChildren(node1));
    try expectChildrenTags(u8, author.view(), node2, &.{ 21, 11, 99 });
}

test "MutableHierarchy: paylod" {
    const Author = MutableHierarchy(.{ .Payload = u8 }, .{});
    var author = Author{};
    defer author.deinit(test_alloc);

    const node1 = try author.appendNode(test_alloc, .none, {}, 1);
    try testing.expectEqual(1, author.view().payload(node1));

    const node2 = try author.appendNode(test_alloc, .none, {}, 2);
    try testing.expectEqual(2, author.view().payload(node2));
    author.dropNode(test_alloc, .none, node2);

    author.setPayload(node1, 18);
    try testing.expectEqual(18, author.view().payload(node1));

    const ref = author.refPayload(node1);
    try testing.expectEqual(18, ref.*);
    ref.* = 8;
    try testing.expectEqual(8, author.view().payload(node1));
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
    author.dropNode(test_alloc, .none, node1);
    try testing.expectEqual(1, Test.count);
    try testing.expectEqual(node1, Test.nodes[0]);

    Test.count = 0;
    node1 = try author.appendNode(test_alloc, .none, {}, {});
    const node2 = try author.appendNode(test_alloc, node1, {}, {});
    author.dropNode(test_alloc, .none, node1);
    try testing.expectEqual(2, Test.count);
    try testing.expectEqual(node1, Test.nodes[0]);
    try testing.expectEqual(node2, Test.nodes[1]);
}

pub fn HierarchyViewer(comptime options: HierarchyOptions) type {
    const Handle = common.Handle(options.Indexer);
    const Iterator = iter.Iterator(Handle, .{});

    return struct {
        const Self = @This();

        nodes: cols.ColumnsViewer(options.Indexer, HierarchyNode(options)),
        adjacents: rows.RowsViewer(options.Indexer, Handle),

        pub fn tag(self: Self, node: Handle) options.Tag {
            comptime assert(options.Tag != void);
            assert(node != .none);
            return self.nodes.peekField(@intFromEnum(node), .tag);
        }

        pub fn payload(self: Self, node: Handle) options.Payload {
            comptime assert(options.Payload != void);
            assert(node != .none);
            return self.nodes.peekField(@intFromEnum(node), .payload);
        }

        pub fn childAt(self: Self, parent: Handle, i: usize) Handle {
            assert(parent != .none);
            const list = self.nodes.peekField(@intFromEnum(parent), .children);
            assert(list != .none);
            return self.adjacents.itemAt(@intFromEnum(list), @intCast(i));
        }

        pub fn childAtOrNull(self: Self, parent: Handle, i: usize) ?Handle {
            assert(parent != .none);
            const list = self.nodes.peekField(@intFromEnum(parent), .children);
            return switch (list) {
                .none => null,
                else => self.adjacents.itemAtOrNull(@intFromEnum(list), @intCast(i)),
            };
        }

        pub fn findChild(self: Self, parent: if (options.inverse) void else Handle, child: Handle) options.Indexer {
            assert(child != .none);

            const pid = if (options.inverse) self.nodes.peekField(@intFromEnum(child), .parent) else parent;
            assert(pid != Handle.none);

            const list = self.nodes.peekField(@intFromEnum(pid), .children);
            assert(list != .none);

            return self.adjacents.findItem(@intFromEnum(list), child);
        }

        pub fn countChildren(self: Self, parent: Handle) options.Indexer {
            assert(parent != .none);
            return switch (self.nodes.peekField(@intFromEnum(parent), .children)) {
                .none => 0,
                else => |list| self.adjacents.countItems(@intFromEnum(list)),
            };
        }

        pub fn iterateChildren(self: Self, parent: Handle) Iterator {
            assert(parent != .none);
            return switch (self.nodes.peekField(@intFromEnum(parent), .children)) {
                .none => .{ .items = &.{} },
                else => |list| self.adjacents.iterateItems(@intFromEnum(list)),
            };
        }
    };
}
