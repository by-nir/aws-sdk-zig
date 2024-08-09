const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const serial = @import("serialize.zig");

const Indexer = u32;

pub const SourceHandle = packed struct {
    offset: Indexer,
    length: Indexer,

    pub const empty = SourceHandle{ .offset = 0, .length = 0 };

    pub fn isEmpty(self: SourceHandle) bool {
        return self.length == 0;
    }
};

pub fn SourceTree(comptime Tag: type) type {
    if (@bitSizeOf(Tag) != 64) @compileError("SourceTreeAuthor expects the tag’s type to be 64 bits.");

    return struct {
        const Self = @This();

        raw_payload: []const u8,
        children_ids: []const Indexer,
        nodes_tag: []const Tag,
        nodes_payload: []const SourceHandle,
        nodes_children: []const SourceHandle,

        pub fn author(allocator: Allocator) !SourceTreeAuthor(Tag) {
            return SourceTreeAuthor(Tag).init(allocator);
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.raw_payload);
            allocator.free(self.children_ids);
            allocator.free(self.nodes_tag);
            allocator.free(self.nodes_payload);
            allocator.free(self.nodes_children);
        }

        pub fn iterate(self: *const Self) Iterator {
            const slice = self.nodes_children[0];
            return Iterator{
                .tree = self,
                .indices = self.children_ids[slice.offset..][0..slice.length],
            };
        }

        fn node(self: *const Self, index: Indexer) Node {
            const raw_payload = blk: {
                const handle = self.nodes_payload[index];
                break :blk self.raw_payload[handle.offset..][0..handle.length];
            };

            const children_ids = blk: {
                const handle = self.nodes_children[index];
                break :blk self.children_ids[handle.offset..][0..handle.length];
            };

            return Node{
                .tree = self,
                .tag = self.nodes_tag[index],
                .raw_payload = raw_payload,
                .children_ids = children_ids,
            };
        }

        pub const Node = struct {
            tree: *const Self,
            tag: Tag,
            raw_payload: []const u8,
            children_ids: []const Indexer,

            pub fn child(self: Node, index: usize) ?Node {
                if (index >= self.children_ids.len) return null;
                return self.tree.node(self.children_ids[index]);
            }

            pub fn payload(self: Node, comptime T: type) T {
                var reader = serial.SerialReader{
                    .buffer = self.raw_payload,
                };
                return reader.next(T);
            }

            pub fn iterate(self: Node) Iterator {
                return Iterator{
                    .tree = self.tree,
                    .indices = self.children_ids,
                };
            }
        };

        pub const Iterator = struct {
            tree: *const Self,
            indices: []const Indexer,

            pub fn skip(self: *Iterator, count: Indexer) void {
                std.debug.assert(count <= self.indices.len);
                self.indices = self.indices[count..self.indices.len];
            }

            pub fn peek(self: *const Iterator) ?Node {
                if (self.indices.len == 0) return null;
                const index = self.indices[0];
                return self.tree.node(index);
            }

            pub fn next(self: *Iterator) ?Node {
                if (self.indices.len == 0) return null;
                defer self.indices = self.indices[1..self.indices.len];

                const index = self.indices[0];
                return self.tree.node(index);
            }
        };
    };
}

test "SouceTree" {
    const payload = &[_]u8{2} ++ std.mem.asBytes(&@as(u16, 6)) ++ "foo108" ++ &[_]u8{ 1, 3 } ++ "bar";
    const tree = SourceTree(u64){
        .raw_payload = payload,
        .children_ids = &.{ 2, 3, 1, 4 },
        .nodes_tag = &.{ 0, 101, 201, 202, 102 },
        .nodes_payload = &.{
            SourceHandle.empty,
            SourceHandle.empty,
            .{ .offset = 9, .length = 5 },
            SourceHandle.empty,
            .{ .offset = 0, .length = 9 },
        },
        .nodes_children = &.{
            .{ .offset = 2, .length = 2 },
            .{ .offset = 0, .length = 2 },
            SourceHandle.empty,
            SourceHandle.empty,
            SourceHandle.empty,
        },
    };

    try expectTree(tree);
}

pub fn SourceTreeAuthor(comptime Tag: type) type {
    if (@bitSizeOf(Tag) != 64) @compileError("SourceTreeAuthor expects the tag’s type to be 64 bits.");

    return struct {
        const Self = @This();

        allocator: Allocator,
        nodes_tag: std.ArrayListUnmanaged(Tag),
        nodes_payload: std.ArrayListUnmanaged(SourceHandle),
        nodes_children: std.ArrayListUnmanaged(SourceHandle),
        root_children: std.ArrayListUnmanaged(Indexer) = .{},
        payload: AuthorPayload = .{},
        children: std.ArrayListUnmanaged(Indexer) = .{},

        pub fn init(allocator: Allocator) !Self {
            var tags = try std.ArrayListUnmanaged(Tag).initCapacity(allocator, 1);
            tags.appendAssumeCapacity(undefined);
            errdefer tags.deinit(allocator);

            var payloads = try std.ArrayListUnmanaged(SourceHandle).initCapacity(allocator, 1);
            payloads.appendAssumeCapacity(SourceHandle.empty);
            errdefer payloads.deinit(allocator);

            var children = try std.ArrayListUnmanaged(SourceHandle).initCapacity(allocator, 1);
            children.appendAssumeCapacity(SourceHandle.empty);
            errdefer children.deinit(allocator);

            return Self{
                .allocator = allocator,
                .nodes_tag = tags,
                .nodes_payload = payloads,
                .nodes_children = children,
            };
        }

        /// Do not call if already consumed.
        pub fn deinit(self: *Self) void {
            self.payload.deinit(self.allocator);
            self.children.deinit(self.allocator);
            self.nodes_tag.deinit(self.allocator);
            self.nodes_payload.deinit(self.allocator);
            self.nodes_children.deinit(self.allocator);
            self.root_children.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn consume(self: *Self) !SourceTree(Tag) {
            const alloc = self.allocator;

            const nodes_tag = try self.nodes_tag.toOwnedSlice(alloc);
            errdefer alloc.free(nodes_tag);

            const nodes_payload = try self.nodes_payload.toOwnedSlice(alloc);
            errdefer alloc.free(nodes_payload);

            self.nodes_children.items[0] = SourceHandle{
                .offset = @truncate(self.children.items.len),
                .length = @truncate(self.root_children.items.len),
            };
            const nodes_children = try self.nodes_children.toOwnedSlice(alloc);
            errdefer alloc.free(nodes_children);

            const raw_payload = try self.payload.consume(alloc);
            errdefer alloc.free(raw_payload);

            try self.children.appendSlice(alloc, self.root_children.items);
            const children_ids = try self.children.toOwnedSlice(alloc);
            errdefer alloc.free(children_ids);

            self.root_children.deinit(alloc);
            self.* = undefined;

            return SourceTree(Tag){
                .raw_payload = raw_payload,
                .children_ids = children_ids,
                .nodes_tag = nodes_tag,
                .nodes_payload = nodes_payload,
                .nodes_children = nodes_children,
            };
        }

        pub fn append(self: *Self, tag: Tag) !Node {
            const node = try self.createNode(tag);
            errdefer self.dropLastNode(node.index);

            try self.root_children.append(self.allocator, node.index);
            return node;
        }

        fn createNode(self: *Self, tag: Tag) !Node {
            const index: Indexer = @truncate(self.nodes_tag.items.len);

            try self.nodes_tag.append(self.allocator, tag);
            errdefer _ = self.nodes_tag.pop();

            try self.nodes_payload.append(self.allocator, SourceHandle.empty);
            errdefer _ = self.nodes_payload.pop();

            try self.nodes_children.append(self.allocator, SourceHandle.empty);
            errdefer _ = self.nodes_children.pop();

            return Node{
                .allocator = self.allocator,
                .tree = self,
                .index = index,
            };
        }

        fn dropLastNode(self: *Self, index: Indexer) void {
            std.debug.assert(index == self.nodes_tag.items.len - 1);
            errdefer _ = self.nodes_tag.pop();
            errdefer _ = self.nodes_payload.pop();
            errdefer _ = self.nodes_children.pop();
        }

        fn sealNode(self: *Self, index: Indexer, payload: SourceHandle, children: []const Indexer) !void {
            const children_len: Indexer = @truncate(children.len);
            const children_offset: Indexer = @truncate(self.children.items.len);
            try self.children.appendSlice(self.allocator, children);
            self.nodes_children.items[index] = SourceHandle{
                .offset = children_offset,
                .length = children_len,
            };

            self.nodes_payload.items[index] = payload;
        }

        pub fn TEMP_overridePayload(self: *Self, node_idx: Indexer, bytes: []const u8) void {
            const handle = self.nodes_payload.items[node_idx];
            self.payload.TEMP_override(handle, bytes);
        }

        pub fn cacheRawPayload(self: *Self, bytes: []const u8) !SourceHandle {
            return try self.payload.cacheRaw(self.allocator, bytes);
        }

        pub const Node = struct {
            allocator: Allocator,
            tree: *Self,
            index: Indexer,
            payload: SourceHandle = SourceHandle.empty,
            children: std.ArrayListUnmanaged(Indexer) = .{},

            pub fn deinit(self: *Node) void {
                self.children.deinit(self.allocator);
            }

            pub fn seal(self: *Node) !void {
                try self.tree.sealNode(self.index, self.payload, self.children.items);
                self.children.deinit(self.allocator);
            }

            pub fn append(self: *Node, tag: Tag) !Node {
                const node = try self.tree.createNode(tag);
                errdefer self.tree.dropLastNode(node.index);

                try self.children.append(self.allocator, node.index);
                return node;
            }

            pub fn setPayload(self: *Node, comptime T: type, value: T) !void {
                std.debug.assert(self.payload.isEmpty());
                self.payload = try self.tree.payload.putValue(self.tree.allocator, T, value);
            }

            pub fn setPayloadFmt(self: *Node, comptime format: []const u8, args: anytype) !usize {
                std.debug.assert(self.payload.isEmpty());
                const handle = try self.tree.payload.putFmt(self.tree.allocator, format, args);
                self.payload = handle;
                return handle.length
                // TODO: Remove \/ (when MD no longer requires the text len)
                - 3;
            }
        };
    };
}

test "SourceTreeAuthor" {
    const tree = blk: {
        var author = try SourceTreeAuthor(u64).init(test_alloc);
        errdefer author.deinit();

        try testing.expectEqualDeep(SourceHandle{
            .offset = 0,
            .length = 5,
        }, try author.cacheRawPayload("foo"));

        try testing.expectEqualDeep(SourceHandle{
            .offset = 5,
            .length = 5,
        }, try author.cacheRawPayload("bar"));

        try testing.expectEqualDeep(SourceHandle{
            .offset = 0,
            .length = 5,
        }, try author.cacheRawPayload("foo"));

        var node = try author.append(101);
        errdefer node.deinit();

        var child = try node.append(201);
        errdefer child.deinit();

        try child.setPayload([]const u8, "qux");
        try child.seal();

        author.TEMP_overridePayload(child.index, &[_]u8{ 1, 3 } ++ "bar");

        child = try node.append(202);
        try child.seal();

        try node.seal();

        node = try author.append(102);
        const len = try node.setPayloadFmt("foo{d}", .{108});
        try testing.expectEqual(6, len);
        try node.seal();

        break :blk try author.consume();
    };
    defer tree.deinit(test_alloc);

    try expectTree(tree);
}

/// 101
///   201 "bar"
///   202
/// 102 "foo"
fn expectTree(tree: SourceTree(u64)) !void {
    var iter = tree.iterate();
    var node = iter.next().?;
    try testing.expectEqual(101, node.tag);

    var chuld_iter = node.iterate();
    var child = chuld_iter.next().?;
    try testing.expectEqual(201, child.tag);
    try testing.expectEqualStrings("bar", child.payload([]const u8));
    child = chuld_iter.next().?;
    try testing.expectEqual(202, child.tag);
    try testing.expectEqual(null, chuld_iter.next());

    node = iter.next().?;
    try testing.expectEqual(102, node.tag);
    try testing.expectEqualStrings("foo108", node.payload([]const u8));
    try testing.expectEqual(null, iter.next());
}

const AuthorPayload = struct {
    serial: serial.SerialWriter = .{},
    cache: std.StringHashMapUnmanaged(SourceHandle) = .{},

    pub fn deinit(self: *AuthorPayload, allocator: Allocator) void {
        self.serial.deinit(allocator);
        self.cache.deinit(allocator);
    }

    pub fn consume(self: *AuthorPayload, allocator: Allocator) ![]const u8 {
        const buffer = try self.serial.consumeSlice(allocator);
        self.cache.deinit(allocator);
        return buffer;
    }

    pub fn putValue(self: *AuthorPayload, allocator: Allocator, comptime T: type, value: T) !SourceHandle {
        const handle = try self.serial.append(allocator, T, value);
        return fromSerialHandle(handle);
    }

    pub fn putFmt(self: *AuthorPayload, allocator: Allocator, comptime format: []const u8, args: anytype) !SourceHandle {
        const handle = try self.serial.appendFmt(allocator, format, args);
        return fromSerialHandle(handle);
    }

    pub fn cacheRaw(self: *AuthorPayload, allocator: Allocator, bytes: []const u8) !SourceHandle {
        const result = try self.cache.getOrPut(allocator, bytes);
        errdefer _ = self.cache.remove(bytes);

        if (result.found_existing) {
            return result.value_ptr.*;
        } else {
            const serial_handle = try self.serial.append(allocator, []const u8, bytes);
            const source_handle = fromSerialHandle(serial_handle);
            result.value_ptr.* = source_handle;
            return source_handle;
        }
    }

    pub fn TEMP_override(self: *AuthorPayload, handle: SourceHandle, bytes: []const u8) void {
        self.serial.TEMP_override(toSerialHandle(handle), bytes);
    }

    fn fromSerialHandle(handle: serial.SerialHandle) SourceHandle {
        return .{
            .offset = @truncate(handle.offset),
            .length = @truncate(handle.length),
        };
    }

    fn toSerialHandle(handle: SourceHandle) serial.SerialHandle {
        return .{
            .offset = handle.offset,
            .length = handle.length,
        };
    }
};

test "AuthorPayload" {
    const buffer = blk: {
        var author = AuthorPayload{};
        errdefer author.deinit(test_alloc);

        var handle = try author.putValue(test_alloc, []const u8, "qux");
        try testing.expectEqualDeep(SourceHandle{
            .offset = 0,
            .length = 5,
        }, handle);
        author.TEMP_override(handle, &[_]u8{ 1, 3 } ++ "foo");

        handle = try author.putFmt(test_alloc, " bar {s}", .{"baz"});
        try testing.expectEqualDeep(SourceHandle{
            .offset = 5,
            .length = 11,
        }, handle);

        try testing.expectEqualDeep(SourceHandle{
            .offset = 16,
            .length = 5,
        }, try author.cacheRaw(test_alloc, "foo"));

        try testing.expectEqualDeep(SourceHandle{
            .offset = 21,
            .length = 5,
        }, try author.cacheRaw(test_alloc, "bar"));

        try testing.expectEqualDeep(SourceHandle{
            .offset = 16,
            .length = 5,
        }, try author.cacheRaw(test_alloc, "foo"));

        break :blk try author.consume(test_alloc);
    };

    defer test_alloc.free(buffer);
    const expected = &[_]u8{ 1, 3 } ++ "foo" ++
        &[_]u8{2} ++ std.mem.asBytes(&@as(u16, 8)) ++ " bar baz" ++
        &[_]u8{ 1, 3 } ++ "foo" ++ &[_]u8{ 1, 3 } ++ "bar";
    try testing.expectEqualSlices(u8, expected, buffer);
}
