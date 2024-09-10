const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const srl = @import("serialize.zig");
const iter = @import("utils/iterate.zig");
const common = @import("utils/common.zig");
const hrcy = @import("utils/hierarchy.zig");

const Indexer = u32;
pub const ROOT = NodeHandle.of(0);
pub const PayloadHandle = srl.SerialHandle;
pub const NodeHandle = common.Handle(Indexer);
pub const Iterator = iter.Iterator(NodeHandle, .{});

fn optnsFor(comptime Tag: type) hrcy.HieararchyOptions {
    return .{
        .Tag = Tag,
        .Indexer = Indexer,
        .Payload = PayloadHandle,
        .inverse = true,
    };
}

pub fn SourceTree(comptime Tag: type) type {
    return struct {
        const Self = @This();
        pub const Viewer = SourceViewer(Tag);

        payload: srl.SerialViewer,
        hierarchy: hrcy.Hierarchy(optnsFor(Tag)),

        pub fn deinit(self: Self, allocator: Allocator) void {
            self.hierarchy.deinit(allocator);
            allocator.free(self.payload.buffer);
        }

        pub fn view(self: *const Self) Viewer {
            return .{
                .serial = self.payload,
                .hierarchy = self.hierarchy.view(),
            };
        }
    };
}

pub fn MutableSourceTree(comptime Tag: type) type {
    const Hierarchy = hrcy.MutableHierarchy(optnsFor(Tag), .{});

    return struct {
        const Self = @This();
        pub const Viewer = SourceViewer(Tag);

        allocator: Allocator,
        hierarchy: Hierarchy = .{},
        payload: MutablePayload = .{},

        pub fn init(allocator: Allocator, root: Tag) !Self {
            var self = Self{ .allocator = allocator };
            const handle = try self.appendNode(.none, root);
            std.debug.assert(handle == ROOT);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.payload.deinit(self.allocator);
            self.hierarchy.deinit(self.allocator);
        }

        pub fn view(self: *const Self) Viewer {
            return .{
                .serial = self.payload.serial.view(),
                .hierarchy = self.hierarchy.view(),
            };
        }

        /// The caller owns the returned memory. Clears the mutable tree.
        pub fn toReadOnly(self: *Self, immut_alloc: Allocator) !SourceTree(Tag) {
            var payload: MutablePayload = .{};
            var hierarchy = hrcy.Hierarchy(optnsFor(Tag)).author(immut_alloc);
            errdefer hierarchy.deinit();

            const hier_view = self.hierarchy.view();
            const handle = self.toOwnedNode(immut_alloc, hier_view, &hierarchy, &payload, .none, ROOT) catch |err| {
                payload.deinit(immut_alloc);
                return err;
            };
            assert(handle == ROOT);

            const ro_payload = payload.toOwnedSerial(immut_alloc) catch |err| {
                payload.deinit(immut_alloc);
                return err;
            };
            const ro_hierarchy = hierarchy.consume() catch |err| {
                immut_alloc.free(ro_payload.buffer);
                return err;
            };

            self.deinit();
            return .{
                .payload = ro_payload,
                .hierarchy = ro_hierarchy,
            };
        }

        fn toOwnedNode(
            self: *const Self,
            immut_alloc: Allocator,
            hier_view: Hierarchy.Viewer,
            hier_author: *hrcy.Hierarchy(optnsFor(Tag)).Author,
            payload: *MutablePayload,
            parent: NodeHandle,
            node: NodeHandle,
        ) !NodeHandle {
            const new_payload = blk: {
                const handle: PayloadHandle = hier_view.payload(node);
                if (handle.isEmpty())
                    break :blk PayloadHandle.empty
                else
                    break :blk try payload.putRaw(immut_alloc, self.payload.getRaw(handle));
            };
            const new_node = try hier_author.appendNode(parent, hier_view.tag(node), new_payload);
            const children = try hier_author.reserveChildren(new_node, hier_view.countChildren(node));

            var i: usize = 0;
            var it = hier_view.iterateChildren(node);
            while (it.next()) |child| : (i += 1) {
                const item = try self.toOwnedNode(immut_alloc, hier_view, hier_author, payload, new_node, child);
                children.setItem(i, item);
            }

            return new_node;
        }

        pub fn appendNode(self: *Self, parent: NodeHandle, tag: Tag) !NodeHandle {
            return self.hierarchy.appendNode(self.allocator, parent, tag, PayloadHandle.empty);
        }

        pub fn appendNodePayload(self: *Self, parent: NodeHandle, tag: Tag, comptime T: type, value: T) !NodeHandle {
            const payload = try self.payload.putValue(self.allocator, T, value);
            errdefer self.payload.drop(payload);
            return self.hierarchy.appendNode(self.allocator, parent, tag, payload);
        }

        pub fn appendNodePayloadFmt(self: *Self, parent: NodeHandle, tag: Tag, comptime format: []const u8, args: anytype) !NodeHandle {
            const payload = try self.payload.putFmt(self.allocator, format, args);
            errdefer self.payload.drop(payload);
            return self.hierarchy.appendNode(self.allocator, parent, tag, payload);
        }

        pub fn insertNode(self: *Self, parent: NodeHandle, i: Indexer, tag: Tag) !NodeHandle {
            return self.hierarchy.insertNode(self.allocator, parent, i, tag, PayloadHandle.empty);
        }

        pub fn insertNodePayload(self: *Self, parent: NodeHandle, i: Indexer, tag: Tag, comptime T: type, value: T) !NodeHandle {
            const payload = try self.payload.putValue(self.allocator, T, value);
            errdefer self.payload.drop(payload);
            return self.hierarchy.insertNode(self.allocator, parent, i, tag, payload);
        }

        pub fn insertNodePayloadFmt(self: *Self, parent: NodeHandle, i: Indexer, tag: Tag, comptime format: []const u8, args: anytype) !NodeHandle {
            const payload = try self.payload.putFmt(self.allocator, format, args);
            errdefer self.payload.drop(payload);
            return self.hierarchy.insertNode(self.allocator, parent, i, tag, payload);
        }

        pub fn dropNode(self: *Self, node: NodeHandle) void {
            self.hierarchy.dropNode(self.allocator, .ordered, {}, node);
        }

        pub fn setPayload(self: *Self, node: NodeHandle, comptime T: type, value: T) !void {
            const handle: *PayloadHandle = self.hierarchy.refPayload(node);
            if (handle.*.isEmpty()) {
                handle.* = try self.payload.putValue(self.allocator, T, value);
            } else if (MutablePayload.canOverride(handle.*, T, value)) {
                self.payload.override(handle.*, T, value);
            } else {
                const new_handle = try self.payload.putValue(self.allocator, T, value);
                self.payload.drop(handle.*);
                handle.* = new_handle;
            }
        }

        pub fn setPayloadFmt(self: *Self, node: NodeHandle, comptime format: []const u8, args: anytype) !usize {
            const string = try self.payload.putFmt(self.allocator, format, args);

            const handle: *PayloadHandle = self.hierarchy.refPayload(node);
            if (!handle.*.isEmpty()) self.payload.drop(handle.*);

            handle.* = string;
            return string.length - 3; // 3 bytes are used to encode string’s length
        }
    };
}

pub fn SourceViewer(comptime Tag: type) type {
    return struct {
        const Self = @This();

        serial: srl.SerialViewer,
        hierarchy: hrcy.HierarchyViewer(optnsFor(Tag)),

        pub fn tag(self: Self, node: NodeHandle) Tag {
            return self.hierarchy.tag(node);
        }

        pub fn payload(self: Self, node: NodeHandle, comptime T: type) T {
            const handle = self.hierarchy.payload(node);
            return self.serial.get(T, handle);
        }

        pub fn countChildren(self: Self, parent: NodeHandle) Indexer {
            return self.hierarchy.countChildren(parent);
        }

        pub fn childAt(self: Self, parent: NodeHandle, index: usize) NodeHandle {
            return self.hierarchy.childAt(parent, index);
        }

        pub fn childAtOrNull(self: Self, parent: NodeHandle, index: usize) ?NodeHandle {
            return self.hierarchy.childAtOrNull(parent, index);
        }

        pub fn iterateChildren(self: Self, parent: NodeHandle) Iterator {
            return self.hierarchy.iterateChildren(parent);
        }
    };
}

test {
    const tree = blk: {
        var tree = try MutableSourceTree(u8).init(test_alloc, 0);
        errdefer tree.deinit();

        try testing.expectEqual(0, tree.view().countChildren(ROOT));

        var node1 = try tree.appendNodePayload(ROOT, 0, []const u8, "baz");
        try testing.expectEqual(1, @intFromEnum(node1));
        try testing.expectEqual(1, tree.view().countChildren(ROOT));

        tree.dropNode(node1);
        try testing.expectEqual(0, tree.view().countChildren(ROOT));

        const node2 = try tree.appendNode(ROOT, 2);

        node1 = try tree.insertNode(ROOT, 0, 1);
        try testing.expectEqual(node1, tree.view().childAt(ROOT, 0));
        try testing.expectEqual(node1, tree.view().childAtOrNull(ROOT, 0));
        try testing.expectEqual(null, tree.view().childAtOrNull(ROOT, 2));

        try tree.setPayload(node1, []const u8, "foo"); // new
        try tree.setPayload(node1, []const u8, "bar"); // override matching
        try tree.setPayload(node1, []const u8, "foo108"); // override longer

        try testing.expectEqual(6, try tree.setPayloadFmt(node2, "foo{d}", .{107})); // new
        try testing.expectEqual(6, try tree.setPayloadFmt(node2, "bar{d}", .{108})); // override

        var it = tree.view().iterateChildren(ROOT);
        try testing.expectEqual(node1, it.next());
        try testing.expectEqual(node2, it.next());
        try testing.expectEqual(null, it.next());

        break :blk try tree.toReadOnly(test_alloc);
    };

    const view = tree.view();
    defer tree.deinit(test_alloc);

    try testing.expectEqual(0, view.tag(ROOT));
    try testing.expectEqual(2, view.countChildren(ROOT));
    try testing.expectEqual(NodeHandle.of(2), view.childAt(ROOT, 1));
    try testing.expectEqual(NodeHandle.of(2), view.childAtOrNull(ROOT, 1));
    try testing.expectEqual(null, view.childAtOrNull(ROOT, 2));

    try testing.expectEqual(1, view.tag(NodeHandle.of(1)));
    try testing.expectEqual(0, view.countChildren(NodeHandle.of(1)));
    try testing.expectEqualStrings("foo108", view.payload(NodeHandle.of(1), []const u8));

    try testing.expectEqual(2, view.tag(NodeHandle.of(2)));
    try testing.expectEqualStrings("bar108", view.payload(NodeHandle.of(2), []const u8));

    var it = view.iterateChildren(ROOT);
    try testing.expectEqual(NodeHandle.of(1), it.next());
    try testing.expectEqual(NodeHandle.of(2), it.next());
    try testing.expectEqual(null, it.next());
}

const MutablePayload = struct {
    serial: srl.SerialWriter = .{},
    cache: std.StringHashMapUnmanaged(PayloadHandle) = .{},

    pub fn deinit(self: *MutablePayload, allocator: Allocator) void {
        self.serial.deinit(allocator);
        self.cache.deinit(allocator);
    }

    /// The caller owns the returned memory.
    pub fn toOwnedSerial(self: *MutablePayload, allocator: Allocator) !srl.SerialViewer {
        const view = try self.serial.toOwnedViewer(allocator);
        self.cache.deinit(allocator);
        return view;
    }

    pub fn getRaw(self: MutablePayload, handle: PayloadHandle) []const u8 {
        const buffer = self.serial.buffer.items;
        assert(handle.offset + handle.length <= buffer.len);
        return buffer[handle.offset..][0..handle.length];
    }

    pub fn getValue(self: MutablePayload, comptime T: type, handle: PayloadHandle) T {
        return self.serial.view().get(T, handle);
    }

    pub fn putRaw(self: *MutablePayload, allocator: Allocator, bytes: []const u8) !PayloadHandle {
        return self.serial.appendRaw(allocator, bytes, true);
    }

    pub fn putValue(self: *MutablePayload, allocator: Allocator, comptime T: type, value: T) !PayloadHandle {
        return self.serial.append(allocator, T, value);
    }

    pub fn putFmt(self: *MutablePayload, allocator: Allocator, comptime format: []const u8, args: anytype) !PayloadHandle {
        return self.serial.appendFmt(allocator, format, args);
    }

    pub fn cacheRaw(self: *MutablePayload, allocator: Allocator, bytes: []const u8) !PayloadHandle {
        const result = try self.cache.getOrPut(allocator, bytes);
        errdefer _ = self.cache.remove(bytes);

        if (result.found_existing) {
            return result.value_ptr.*;
        } else {
            const handle = try self.serial.append(allocator, []const u8, bytes);
            result.value_ptr.* = handle;
            return handle;
        }
    }

    pub fn canOverride(handle: PayloadHandle, comptime T: type, value: T) bool {
        return srl.SerialWriter.canOverride(handle, T, value);
    }

    pub fn override(self: *MutablePayload, handle: PayloadHandle, comptime T: type, value: T) void {
        self.serial.override(handle, T, value);
    }

    pub fn drop(self: *MutablePayload, handle: PayloadHandle) void {
        if (self.serial.length() == handle.offset + handle.length) {
            self.serial.drop(handle.length);
        } else {
            self.serial.invalidate(handle);
        }
    }
};

test "MutablePayload" {
    const view = blk: {
        var author = MutablePayload{};
        errdefer author.deinit(test_alloc);

        var handle = try author.putValue(test_alloc, []const u8, "qux");
        try testing.expectEqualDeep(PayloadHandle{
            .offset = 0,
            .length = 5,
        }, handle);
        author.override(handle, []const u8, "foo");

        handle = try author.putFmt(test_alloc, " bar {s}", .{"baz"});
        try testing.expectEqualDeep(PayloadHandle{
            .offset = 5,
            .length = 11,
        }, handle);

        try testing.expectEqualDeep(PayloadHandle{
            .offset = 16,
            .length = 5,
        }, try author.cacheRaw(test_alloc, "foo"));

        try testing.expectEqualDeep(PayloadHandle{
            .offset = 21,
            .length = 5,
        }, try author.cacheRaw(test_alloc, "bar"));

        try testing.expectEqualDeep(PayloadHandle{
            .offset = 16,
            .length = 5,
        }, try author.cacheRaw(test_alloc, "foo"));

        const raw_handle = try author.putRaw(test_alloc, "foo");
        try testing.expectEqualDeep(PayloadHandle{
            .offset = 26,
            .length = 3,
        }, raw_handle);
        try testing.expectEqualStrings("foo", author.getRaw(raw_handle));

        break :blk try author.toOwnedSerial(test_alloc);
    };

    defer view.deinit(test_alloc);
    const expected = &[_]u8{ 1, 3 } ++ "foo" ++
        &[_]u8{2} ++ std.mem.asBytes(&@as(u16, 8)) ++ " bar baz" ++
        &[_]u8{ 1, 3 } ++ "foo" ++ &[_]u8{ 1, 3 } ++ "bar" ++ "foo";
    try testing.expectEqualSlices(u8, expected, view.buffer);
}
