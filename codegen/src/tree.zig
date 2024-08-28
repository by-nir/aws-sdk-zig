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
pub const PayloadHandle = srl.SerialHandle;
pub const NodeHandle = common.Handle(Indexer);
pub const Iterator = iter.Iterator(NodeHandle, .{});

pub const ROOT = NodeHandle.of(0);

pub fn ReadOnlySourceTree(comptime Tag: type) type {
    return struct {
        const Self = @This();

        buffer: []const u8,
        hierarchy: hrcy.ReadOnlyHierarchy(.{
            .Tag = Tag,
            .Indexer = Indexer,
            .Payload = PayloadHandle,
            .inverse = true,
        }),

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.buffer);
            self.hierarchy.deinit(allocator);
        }

        pub fn tag(self: Self, node: NodeHandle) Tag {
            return self.hierarchy.query().getTag(node);
        }

        pub fn payload(self: Self, node: NodeHandle, comptime T: type) T {
            const handle = self.hierarchy.query().getPayload(node);
            const buffer = self.buffer[handle.offset..][0..handle.length];
            var reader = srl.SerialReader{ .buffer = buffer };
            return reader.next(T);
        }

        pub fn childCount(self: Self, parent: NodeHandle) Indexer {
            return self.hierarchy.query().childCount(parent);
        }

        pub fn childAt(self: Self, parent: NodeHandle, index: usize) NodeHandle {
            return self.hierarchy.query().childAt(parent, index);
        }

        pub fn childAtOrNull(self: Self, parent: NodeHandle, index: usize) ?NodeHandle {
            return self.hierarchy.query().childAtOrNull(parent, index);
        }

        pub fn iterateChildren(self: Self, parent: NodeHandle) Iterator {
            return self.hierarchy.query().iterateChildren(parent);
        }
    };
}

pub fn MutableSourceTree(comptime Tag: type) type {
    const options: hrcy.HieararchyOptions = .{
        .Tag = Tag,
        .Indexer = Indexer,
        .Payload = PayloadHandle,
        .inverse = true,
    };
    const Hierarchy = hrcy.MutableHierarchy(options, .{});

    return struct {
        const Self = @This();

        allocator: Allocator,
        hierarchy: Hierarchy = .{},
        payload: PayloadAuthor = .{},

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

        pub fn consumeReadOnly(self: *Self, immut_alloc: Allocator) !ReadOnlySourceTree(Tag) {
            var payload: PayloadAuthor = .{};
            var hierarchy = hrcy.ReadOnlyHierarchy(options).author(immut_alloc);
            errdefer hierarchy.deinit();

            const query = self.hierarchy.query();
            const handle = self.consumeNode(immut_alloc, query, &hierarchy, &payload, .none, ROOT) catch |err| {
                payload.deinit(immut_alloc);
                return err;
            };
            assert(handle == ROOT);

            const ro_payload = payload.consume(immut_alloc) catch |err| {
                payload.deinit(immut_alloc);
                return err;
            };
            const ro_hierarchy = hierarchy.consume() catch |err| {
                immut_alloc.free(ro_payload);
                return err;
            };

            self.deinit();
            return .{
                .buffer = ro_payload,
                .hierarchy = ro_hierarchy,
            };
        }

        fn consumeNode(
            self: *const Self,
            immut_alloc: Allocator,
            query: Hierarchy.Query,
            hierarchy: *hrcy.ReadOnlyHierarchy(options).Author,
            payload: *PayloadAuthor,
            parent: NodeHandle,
            node: NodeHandle,
        ) !NodeHandle {
            const new_payload = blk: {
                const handle: PayloadHandle = query.getPayload(node);
                if (handle.isEmpty())
                    break :blk PayloadHandle.empty
                else
                    break :blk try payload.putRaw(immut_alloc, self.payload.getRaw(handle));
            };
            const new_node = try hierarchy.appendNode(parent, query.getTag(node), new_payload);
            const children = try hierarchy.reserveChildren(new_node, query.childCount(node));

            var i: usize = 0;
            var it = query.iterateChildren(node);
            while (it.next()) |child| : (i += 1) {
                const item = try self.consumeNode(immut_alloc, query, hierarchy, payload, new_node, child);
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

        pub fn insertNode(self: *Self, parent: NodeHandle, i: Indexer, tag: Tag) !NodeHandle {
            return self.hierarchy.insertNode(self.allocator, parent, i, tag, PayloadHandle.empty);
        }

        pub fn insertNodePayload(self: *Self, parent: NodeHandle, i: Indexer, tag: Tag, comptime T: type, value: T) !NodeHandle {
            const payload = try self.payload.putValue(self.allocator, T, value);
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
            } else if (PayloadAuthor.canOverride(handle.*, T, value)) {
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
            return string.length - 3;
        }

        pub fn childCount(self: Self, parent: NodeHandle) Indexer {
            return self.hierarchy.query().childCount(parent);
        }

        pub fn childAt(self: Self, parent: NodeHandle, index: usize) NodeHandle {
            return self.hierarchy.query().childAt(parent, index);
        }

        pub fn childAtOrNull(self: Self, parent: NodeHandle, index: usize) ?NodeHandle {
            return self.hierarchy.query().childAtOrNull(parent, index);
        }

        pub fn iterateChildren(self: Self, parent: NodeHandle) Iterator {
            return self.hierarchy.query().iterateChildren(parent);
        }
    };
}

test {
    const tree = blk: {
        var tree = try MutableSourceTree(u8).init(test_alloc, 0);
        errdefer tree.deinit();

        try testing.expectEqual(0, tree.childCount(ROOT));

        var node1 = try tree.appendNodePayload(ROOT, 0, []const u8, "baz");
        try testing.expectEqual(1, @intFromEnum(node1));
        try testing.expectEqual(1, tree.childCount(ROOT));

        tree.dropNode(node1);
        try testing.expectEqual(0, tree.childCount(ROOT));

        const node2 = try tree.appendNode(ROOT, 2);

        node1 = try tree.insertNode(ROOT, 0, 1);
        try testing.expectEqual(node1, tree.childAt(ROOT, 0));
        try testing.expectEqual(node1, tree.childAtOrNull(ROOT, 0));
        try testing.expectEqual(null, tree.childAtOrNull(ROOT, 2));

        try tree.setPayload(node1, []const u8, "foo"); // new
        try tree.setPayload(node1, []const u8, "bar"); // override matching
        try tree.setPayload(node1, []const u8, "foo108"); // override longer

        try testing.expectEqual(6, try tree.setPayloadFmt(node2, "foo{d}", .{107})); // new
        try testing.expectEqual(6, try tree.setPayloadFmt(node2, "bar{d}", .{108})); // override

        var it = tree.iterateChildren(ROOT);
        try testing.expectEqual(node1, it.next());
        try testing.expectEqual(node2, it.next());
        try testing.expectEqual(null, it.next());

        break :blk try tree.consumeReadOnly(test_alloc);
    };
    defer tree.deinit(test_alloc);

    try testing.expectEqual(0, tree.tag(ROOT));
    try testing.expectEqual(2, tree.childCount(ROOT));
    try testing.expectEqual(NodeHandle.of(2), tree.childAt(ROOT, 1));
    try testing.expectEqual(NodeHandle.of(2), tree.childAtOrNull(ROOT, 1));
    try testing.expectEqual(null, tree.childAtOrNull(ROOT, 2));

    try testing.expectEqual(1, tree.tag(NodeHandle.of(1)));
    try testing.expectEqual(0, tree.childCount(NodeHandle.of(1)));
    try testing.expectEqualStrings("foo108", tree.payload(NodeHandle.of(1), []const u8));

    try testing.expectEqual(2, tree.tag(NodeHandle.of(2)));
    try testing.expectEqualStrings("bar108", tree.payload(NodeHandle.of(2), []const u8));

    var it = tree.iterateChildren(ROOT);
    try testing.expectEqual(NodeHandle.of(1), it.next());
    try testing.expectEqual(NodeHandle.of(2), it.next());
    try testing.expectEqual(null, it.next());
}

const PayloadAuthor = struct {
    serial: srl.SerialWriter = .{},
    cache: std.StringHashMapUnmanaged(PayloadHandle) = .{},

    pub fn deinit(self: *PayloadAuthor, allocator: Allocator) void {
        self.serial.deinit(allocator);
        self.cache.deinit(allocator);
    }

    pub fn consume(self: *PayloadAuthor, allocator: Allocator) ![]const u8 {
        const buffer = try self.serial.consumeSlice(allocator);
        self.cache.deinit(allocator);
        return buffer;
    }

    pub fn getRaw(self: PayloadAuthor, handle: PayloadHandle) []const u8 {
        const buffer = self.serial.buffer.items;
        assert(handle.offset + handle.length <= buffer.len);
        return buffer[handle.offset..][0..handle.length];
    }

    pub fn putRaw(self: *PayloadAuthor, allocator: Allocator, bytes: []const u8) !PayloadHandle {
        return self.serial.appendRaw(allocator, bytes, true);
    }

    pub fn putValue(self: *PayloadAuthor, allocator: Allocator, comptime T: type, value: T) !PayloadHandle {
        return self.serial.append(allocator, T, value);
    }

    pub fn putFmt(self: *PayloadAuthor, allocator: Allocator, comptime format: []const u8, args: anytype) !PayloadHandle {
        return self.serial.appendFmt(allocator, format, args);
    }

    pub fn cacheRaw(self: *PayloadAuthor, allocator: Allocator, bytes: []const u8) !PayloadHandle {
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

    pub fn override(self: *PayloadAuthor, handle: PayloadHandle, comptime T: type, value: T) void {
        self.serial.override(handle, T, value);
    }

    pub fn drop(self: *PayloadAuthor, handle: PayloadHandle) void {
        if (self.serial.length() == handle.offset + handle.length) {
            self.serial.drop(handle.length);
        } else {
            self.serial.invalidate(handle);
        }
    }
};

test "PayloadAuthor" {
    const buffer = blk: {
        var author = PayloadAuthor{};
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

        break :blk try author.consume(test_alloc);
    };

    defer test_alloc.free(buffer);
    const expected = &[_]u8{ 1, 3 } ++ "foo" ++
        &[_]u8{2} ++ std.mem.asBytes(&@as(u16, 8)) ++ " bar baz" ++
        &[_]u8{ 1, 3 } ++ "foo" ++ &[_]u8{ 1, 3 } ++ "bar" ++ "foo";
    try testing.expectEqualSlices(u8, expected, buffer);
}
