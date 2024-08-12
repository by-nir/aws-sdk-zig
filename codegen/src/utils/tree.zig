const std = @import("std");
const debug = std.debug;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const slt = @import("slots.zig");
const iter = @import("iterator.zig");

fn NodeHandle(comptime T: type) type {
    return enum(T) {
        root = std.math.maxInt(T),
        _,
    };
}

fn ResourceHandle(comptime T: type) type {
    return enum(T) {
        none = std.math.maxInt(T),
        _,
    };
}

pub fn MutableTree(comptime Payload: type) type {
    const Indexer = u32;
    const Resource = ResourceHandle(Indexer);

    const with_payload = Payload != void;
    const Node: type = if (with_payload) struct {
        tag: u64,
        payload: Resource = .none,
        children: Resource = .none,
    } else struct {
        tag: u64,
        children: Resource = .none,
    };

    return struct {
        const Self = @This();
        const ChildrenList = std.ArrayListUnmanaged(Handle);
        const NodesMuliSlice = std.MultiArrayList(Node).Slice;
        pub const Handle = NodeHandle(Indexer);
        pub const Iterator = iter.Iterator(Handle, .{});

        allocator: Allocator,
        nodes: std.MultiArrayList(Node) = .{},
        nodes_gaps: slt.DynamicSlots(Indexer) = .{},
        children: std.ArrayListUnmanaged(ChildrenList) = .{},
        children_gaps: slt.DynamicSlots(Indexer) = .{},
        payload: if (with_payload) std.ArrayListUnmanaged(Payload) else void =
            if (with_payload) .{} else {},
        payload_gaps: if (with_payload) slt.DynamicSlots(Indexer) else void =
            if (with_payload) .{} else {},

        /// Do not call if already consumed.
        pub fn deinit(self: *Self) void {
            for (self.children.items) |*list| list.deinit(self.allocator);

            self.nodes.deinit(self.allocator);
            self.nodes_gaps.deinit(self.allocator);
            self.children.deinit(self.allocator);
            self.children_gaps.deinit(self.allocator);
            if (with_payload) {
                self.payload.deinit(self.allocator);
                self.payload_gaps.deinit(self.allocator);
            }
        }

        pub fn appendNode(self: *Self, parent: Handle, tag: u64) !Handle {
            debug.assert(tag != 0);
            const node = try self.claimNodeHandle(tag, .none);
            var multi = self.nodes.slice();
            errdefer self.releaseNodeHandle(&multi, node);

            try self.addNode(&multi, parent, null, node);
            return node;
        }

        pub fn appendNodeWithPayload(self: *Self, parent: Handle, tag: u64, value: Payload) !Handle {
            debug.assert(tag != 0);

            const pld = try self.claimPayloadHandle(value);
            errdefer self.releasePayloadHandle(pld);

            const node = try self.claimNodeHandle(tag, pld);
            var multi = self.nodes.slice();
            errdefer self.releaseNodeHandle(&multi, node);

            try self.addNode(&multi, parent, null, node);
            return node;
        }

        pub fn insertNode(self: *Self, parent: Handle, i: usize, tag: u64) !Handle {
            debug.assert(tag != 0);
            const node = try self.claimNodeHandle(tag, .none);
            var multi = self.nodes.slice();
            errdefer self.releaseNodeHandle(&multi, node);

            try self.addNode(&multi, parent, i, node);
            return node;
        }

        pub fn insertNodeWithPayload(self: *Self, parent: Handle, i: usize, tag: u64, value: Payload) !Handle {
            debug.assert(tag != 0);

            const pld = try self.claimPayloadHandle(value);
            errdefer self.releasePayloadHandle(pld);

            const node = try self.claimNodeHandle(tag, pld);
            var multi = self.nodes.slice();
            errdefer self.releaseNodeHandle(&multi, node);

            try self.addNode(&multi, parent, i, node);
            return node;
        }

        fn addNode(self: *Self, multi: *NodesMuliSlice, parent: Handle, i: ?usize, node: Handle) !void {
            switch (parent) {
                .root => {
                    if (self.children.items.len == 0) _ = try self.claimChildrenHandle();
                    try self.addChild(@enumFromInt(0), i, node);
                },
                else => switch (multi.items(.children)[@intFromEnum(parent)]) {
                    .none => {
                        const list_handle = try self.claimChildrenHandle();
                        debug.assert(@intFromEnum(list_handle) > 0); // 0 is reserved for root
                        errdefer self.releaseChildrenHandle(list_handle);

                        try self.addChild(list_handle, i, node);
                        multi.items(.children)[@intFromEnum(parent)] = list_handle;
                    },
                    else => |list_handle| try self.addChild(list_handle, i, node),
                },
            }
        }

        pub fn dropNode(self: *Self, parent: Handle, child: Handle) void {
            debug.assert(child != .root);
            var multi = self.nodes.slice();
            self.removeNode(&multi, child);

            switch (parent) {
                .root => _ = self.removeChild(@enumFromInt(0), child),
                else => {
                    const list_handle = multi.items(.children)[@intFromEnum(parent)];
                    debug.assert(list_handle != .none);

                    if (self.removeChild(list_handle, child)) {
                        multi.items(.children)[@intFromEnum(parent)] = .none;
                    }
                },
            }
        }

        pub fn dropNodeChildren(self: *Self, parent: Handle) void {
            var multi = self.nodes.slice();
            switch (parent) {
                .root => {
                    if (self.children.items.len == 0) return;
                    self.removeNodes(&multi, @enumFromInt(0));
                },
                else => {
                    const handles = multi.items(.children);
                    switch (handles[@intFromEnum(parent)]) {
                        .none => return,
                        else => |handle| {
                            self.removeNodes(&multi, handle);
                            handles[@intFromEnum(parent)] = .none;
                        },
                    }
                },
            }
        }

        pub fn getNodeOrder(self: Self, parent: Handle, child: Handle) usize {
            const idx = switch (parent) {
                .root => 0,
                else => switch (self.nodes.items(.children)[@intFromEnum(parent)]) {
                    .none => unreachable,
                    else => |idx| @intFromEnum(idx),
                },
            };

            const children = self.children.items[idx].items;
            return std.mem.indexOfScalar(Handle, children, child) orelse unreachable;
        }

        pub fn nodeHasChildren(self: Self, parent: Handle) bool {
            const lists = self.children.items;
            return switch (parent) {
                .root => return lists.len > 0 and lists[0].items.len > 0,
                else => switch (self.nodes.items(.children)[@intFromEnum(parent)]) {
                    .none => false,
                    else => |idx| lists[@intFromEnum(idx)].items.len > 0,
                },
            };
        }

        pub fn nodeChildrenCount(self: Self, parent: Handle) usize {
            const lists = self.children.items;
            return switch (parent) {
                .root => if (lists.len > 0) lists[0].items.len else 0,
                else => switch (self.nodes.items(.children)[@intFromEnum(parent)]) {
                    .none => 0,
                    else => |idx| lists[@intFromEnum(idx)].items.len,
                },
            };
        }

        pub fn iterateNodeChildren(self: Self, parent: Handle) Iterator {
            const lists = self.children.items;
            const nodes: []const Handle = switch (parent) {
                .root => if (lists.len > 0) lists[0].items else &.{},
                else => switch (self.nodes.items(.children)[@intFromEnum(parent)]) {
                    .none => &.{},
                    else => |idx| lists[@intFromEnum(idx)].items,
                },
            };

            return Iterator{ .items = nodes };
        }

        fn removeNodes(self: *Self, multi: *NodesMuliSlice, list: Resource) void {
            const children = self.children.items[@intFromEnum(list)].items;
            for (children) |child| self.removeNode(multi, child);
            self.releaseChildrenHandle(list);
        }

        /// Does not remove the node from its parent’s children list.
        fn removeNode(self: *Self, multi: *NodesMuliSlice, node: Handle) void {
            const children = multi.items(.children)[@intFromEnum(node)];
            const payload = if (with_payload) multi.items(.payload)[@intFromEnum(node)] else {};
            self.releaseNodeHandle(multi, node);

            if (with_payload and payload != .none) self.releasePayloadHandle(payload);
            if (children != .none) self.removeNodes(multi, children);
        }

        fn claimNodeHandle(self: *Self, tag: u64, payload: Resource) !Handle {
            const node: Node = if (with_payload) .{
                .tag = tag,
                .payload = payload,
            } else .{
                .tag = tag,
            };

            if (self.nodes_gaps.takeLast()) |slot| {
                self.nodes.set(slot, node);
                return @enumFromInt(slot);
            } else {
                const handle: Handle = @enumFromInt(self.nodes.len);
                try self.nodes.append(self.allocator, node);
                return handle;
            }
        }

        fn releaseNodeHandle(self: *Self, multi: *NodesMuliSlice, node: Handle) void {
            multi.set(@intFromEnum(node), .{ .tag = 0 });
            self.nodes_gaps.put(self.allocator, @intFromEnum(node)) catch {};
        }

        fn addChild(self: *Self, list: Resource, index: ?usize, child: Handle) !void {
            const children = &self.children.items[@intFromEnum(list)];
            if (index) |i| {
                debug.assert(i <= children.items.len);
                try children.insert(self.allocator, i, child);
            } else {
                try children.append(self.allocator, child);
            }
        }

        /// Returns `true` if the child was the last in the list.
        fn removeChild(self: *Self, list: Resource, child: Handle) bool {
            const children = &self.children.items[@intFromEnum(list)];
            if (children.items.len == 1) {
                debug.assert(children.items[0] == child);
                children.deinit(self.allocator);
                return true;
            } else {
                const idx = std.mem.indexOfScalar(Handle, children.items, child);
                _ = children.orderedRemove(idx orelse unreachable);
                return false;
            }
        }

        fn claimChildrenHandle(self: *Self) !Resource {
            if (self.children_gaps.takeLast()) |slot| {
                return @enumFromInt(slot);
            } else {
                const handle: Resource = @enumFromInt(self.children.items.len);
                try self.children.append(self.allocator, .{});
                return handle;
            }
        }

        fn releaseChildrenHandle(self: *Self, handle: Resource) void {
            const i: Indexer = @intFromEnum(handle);
            if (i > 0 and self.children.items.len == i + 1) {
                var list = self.children.pop();
                list.deinit(self.allocator);
            } else {
                self.children.items[i].clearAndFree(self.allocator);
                self.children_gaps.put(self.allocator, i) catch {};
            }
        }

        pub fn getNodeTag(self: Self, node: Handle) u64 {
            debug.assert(node != .root);

            const tag = self.nodes.items(.tag)[@intFromEnum(node)];
            debug.assert(tag > 0);
            return tag;
        }

        pub fn nodeHasPayload(self: *Self, node: Handle) bool {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            const handle = self.nodes.items(.payload)[@intFromEnum(node)];
            return handle != .none;
        }

        pub fn getNodePayload(self: *Self, node: Handle) Payload {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            const handle = self.nodes.items(.payload)[@intFromEnum(node)];
            debug.assert(handle != .none);
            return self.payload.items[@intFromEnum(handle)];
        }

        pub fn getNodePayloadOrNull(self: *Self, node: Handle) ?Payload {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            switch (self.nodes.items(.payload)[@intFromEnum(node)]) {
                .none => return null,
                else => |handle| return self.payload.items[@intFromEnum(handle)],
            }
        }

        pub fn unsetNodePayload(self: *Self, node: Handle) void {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            const payloads = self.nodes.items(.payload);
            const handle = payloads[@intFromEnum(node)];
            debug.assert(handle != .none);

            self.releasePayloadHandle(handle);
            payloads[@intFromEnum(node)] = .none;
        }

        pub fn setNodePayload(self: *Self, node: Handle, value: Payload) !void {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            const node_pld = &self.nodes.items(.payload)[@intFromEnum(node)];
            switch (node_pld.*) {
                .none => node_pld.* = try self.claimPayloadHandle(value),
                else => |handle| self.payload.items[@intFromEnum(handle)] = value,
            }
        }

        pub fn refNodePayload(self: *Self, node: Handle) *Payload {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            const handle = self.nodes.items(.payload)[@intFromEnum(node)];
            debug.assert(handle != .none);
            return &self.payload.items[@intFromEnum(handle)];
        }

        pub fn refNodePayloadOrNull(self: *Self, node: Handle) ?*Payload {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            switch (self.nodes.items(.payload)[@intFromEnum(node)]) {
                .none => return null,
                else => |handle| return &self.payload.items[@intFromEnum(handle)],
            }
        }

        pub fn refOrCreateNodePayload(self: *Self, node: Handle) !*Payload {
            comptime debug.assert(with_payload);
            debug.assert(node != .root);

            const node_pld = &self.nodes.items(.payload)[@intFromEnum(node)];
            switch (node_pld.*) {
                .none => {
                    const handle = try self.claimPayloadHandle(null);
                    node_pld.* = handle;
                    return &self.payload.items[@intFromEnum(handle)];
                },
                else => |handle| return &self.payload.items[@intFromEnum(handle)],
            }
        }

        fn claimPayloadHandle(self: *Self, payload: ?Payload) !Resource {
            if (self.payload_gaps.takeLast()) |slot| {
                self.payload.items[slot] = payload orelse std.mem.zeroes(Payload);
                return @enumFromInt(slot);
            } else {
                const handle: Resource = @enumFromInt(self.payload.items.len);
                if (payload) |value| {
                    try self.payload.append(self.allocator, value);
                } else {
                    const val = try self.payload.addOne(self.allocator);
                    val.* = std.mem.zeroes(Payload);
                }
                return handle;
            }
        }

        fn releasePayloadHandle(self: *Self, handle: Resource) void {
            self.payload_gaps.put(self.allocator, @intFromEnum(handle)) catch {};
        }
    };
}

fn expectChildrenTags(author: *MutableTree(void), parent: MutableTree(void).Handle, tags: []const u64) !void {
    var it = author.iterateNodeChildren(parent);
    try testing.expectEqual(tags.len, it.length());

    for (tags) |tag| {
        try testing.expectEqual(tag, author.getNodeTag(it.next().?));
    }

    try testing.expectEqual(null, it.next());
}

test "MutableTree: add/remove nodes" {
    var tree = MutableTree(void){ .allocator = test_alloc };
    defer tree.deinit();

    try testing.expectEqual(false, tree.nodeHasChildren(.root));
    try testing.expectEqual(0, tree.nodeChildrenCount(.root));

    var node1 = try tree.appendNode(.root, 1);
    try testing.expectEqual(true, tree.nodeHasChildren(.root));
    try testing.expectEqual(1, tree.nodeChildrenCount(.root));
    try testing.expectEqual(0, tree.getNodeOrder(.root, node1));

    const node2 = try tree.appendNode(.root, 2);
    try testing.expectEqual(2, tree.nodeChildrenCount(.root));
    try testing.expectEqual(1, tree.getNodeOrder(.root, node2));
    try expectChildrenTags(&tree, .root, &.{ 1, 2 });

    tree.dropNode(.root, node1);
    try testing.expectEqual(1, tree.nodeChildrenCount(.root));

    node1 = try tree.insertNode(.root, 0, 1);
    try testing.expectEqual(2, tree.nodeChildrenCount(.root));
    try testing.expectEqual(0, tree.getNodeOrder(.root, node1));
    try expectChildrenTags(&tree, .root, &.{ 1, 2 });

    try testing.expectEqual(false, tree.nodeHasChildren(node2));
    try testing.expectEqual(0, tree.nodeChildrenCount(node2));

    var node21 = try tree.appendNode(node2, 21);
    try testing.expectEqual(true, tree.nodeHasChildren(node2));
    try testing.expectEqual(1, tree.nodeChildrenCount(node2));
    try testing.expectEqual(0, tree.getNodeOrder(node2, node21));

    const node22 = try tree.appendNode(node2, 22);
    try testing.expectEqual(2, tree.nodeChildrenCount(node2));
    try testing.expectEqual(1, tree.getNodeOrder(node2, node22));
    try expectChildrenTags(&tree, node2, &.{ 21, 22 });

    tree.dropNode(node2, node21);
    try testing.expectEqual(1, tree.nodeChildrenCount(node2));

    node21 = try tree.insertNode(node2, 0, 21);
    try testing.expectEqual(2, tree.nodeChildrenCount(node2));
    try testing.expectEqual(0, tree.getNodeOrder(node2, node21));
    try expectChildrenTags(&tree, node2, &.{ 21, 22 });

    tree.dropNode(.root, node2);
    try testing.expectEqual(1, tree.nodeChildrenCount(.root));

    const node11 = try tree.appendNode(node1, 11);
    _ = try tree.appendNode(node1, 12);
    try testing.expectEqual(2, tree.nodeChildrenCount(node1));

    _ = try tree.appendNode(node11, 111);

    tree.dropNodeChildren(node1);
    try testing.expectEqual(false, tree.nodeHasChildren(node1));
    try testing.expectEqual(0, tree.nodeChildrenCount(node1));

    tree.dropNodeChildren(.root);
    try testing.expectEqual(false, tree.nodeHasChildren(.root));
    try testing.expectEqual(0, tree.nodeChildrenCount(.root));
}

test "MutableTree: payload" {
    var tree = MutableTree(u8){ .allocator = test_alloc };
    defer tree.deinit();

    const node = try tree.appendNode(.root, 1);
    try testing.expectEqual(false, tree.nodeHasPayload(node));
    try testing.expectEqual(null, tree.getNodePayloadOrNull(node));
    try testing.expectEqual(null, tree.refNodePayloadOrNull(node));

    try tree.setNodePayload(node, 1); // create
    try testing.expectEqual(true, tree.nodeHasPayload(node));
    try testing.expectEqual(1, tree.getNodePayload(node));
    try testing.expectEqual(1, tree.getNodePayloadOrNull(node));

    var ref = tree.refNodePayload(node);
    try testing.expectEqualDeep(1, ref.*);
    ref.* = 2;
    try testing.expectEqual(2, tree.getNodePayload(node));

    ref = tree.refNodePayloadOrNull(node).?;
    try testing.expectEqualDeep(2, ref.*);
    ref.* = 3;
    try testing.expectEqual(3, tree.getNodePayload(node));

    try tree.setNodePayload(node, 4); // override
    try testing.expectEqual(4, tree.getNodePayload(node));

    tree.unsetNodePayload(node);
    try testing.expectEqual(false, tree.nodeHasPayload(node));

    ref = try tree.refOrCreateNodePayload(node); // create
    try testing.expectEqualDeep(0, ref.*);
    ref.* = 1;
    try testing.expectEqual(1, tree.getNodePayload(node));

    ref = try tree.refOrCreateNodePayload(node); // override
    try testing.expectEqualDeep(1, ref.*);
    ref.* = 2;
    try testing.expectEqual(2, tree.getNodePayload(node));
}
