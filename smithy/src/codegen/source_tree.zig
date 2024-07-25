const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub const Indexer = u32;
pub const Slice = struct {
    offset: Indexer,
    length: Indexer,

    pub const empty = Slice{ .offset = 0, .length = 0 };
};

pub fn SourceTree(comptime Tag: type) type {
    return struct {
        const Self = @This();

        payloads: []const u8,
        children: []const Indexer,
        nodes_tag: []const Tag,
        nodes_payload: []const Slice,
        nodes_children: []const Slice,

        pub fn author(allocator: Allocator) !SourceTreeAuthor(Tag) {
            return SourceTreeAuthor(Tag).init(allocator);
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.payloads);
            allocator.free(self.children);
            allocator.free(self.nodes_tag);
            allocator.free(self.nodes_payload);
            allocator.free(self.nodes_children);
        }

        pub fn iterate(self: *const Self) Iterator {
            const slice = self.nodes_children[0];
            return Iterator{
                .tree = self,
                .indices = self.children[slice.offset..][0..slice.length],
            };
        }

        fn getNode(self: *const Self, index: Indexer) Node {
            const payload = self.nodes_payload[index];
            const children = self.nodes_children[index];
            return Node{
                .tree = self,
                .tag = self.nodes_tag[index],
                .payload = self.payloads[payload.offset..][0..payload.length],
                .children = self.children[children.offset..][0..children.length],
            };
        }

        pub const Node = struct {
            tree: *const Self,
            tag: Tag,
            payload: []const u8,
            children: []const Indexer,

            pub fn child(self: Node, index: Indexer) ?Node {
                if (self.children.len <= index) return null;
                return self.tree.getNode(self.children[index]);
            }

            pub fn iterate(self: Node) Iterator {
                return Iterator{
                    .tree = self.tree,
                    .indices = self.children,
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
                return self.tree.getNode(index);
            }

            pub fn next(self: *Iterator) ?Node {
                if (self.indices.len == 0) return null;
                defer self.indices = self.indices[1..self.indices.len];

                const index = self.indices[0];
                return self.tree.getNode(index);
            }
        };
    };
}

test "Tree" {
    const tree = SourceTree(u8){
        .payloads = "foo108bar",
        .children = &.{ 2, 3, 1, 4 },
        .nodes_tag = &.{ 0, 101, 201, 202, 102 },
        .nodes_payload = &.{
            Slice.empty,
            Slice.empty,
            .{ .offset = 6, .length = 3 },
            Slice.empty,
            .{ .offset = 0, .length = 6 },
        },
        .nodes_children = &.{
            .{ .offset = 2, .length = 2 },
            .{ .offset = 0, .length = 2 },
            Slice.empty,
            Slice.empty,
            Slice.empty,
        },
    };

    try expectTree(tree);
}

pub fn SourceTreeAuthor(comptime Tag: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        nodes_tag: std.ArrayListUnmanaged(Tag),
        nodes_payload: std.ArrayListUnmanaged(Slice),
        nodes_children: std.ArrayListUnmanaged(Slice),
        root_children: std.ArrayListUnmanaged(Indexer) = .{},
        payloads: std.ArrayListUnmanaged(u8) = .{},
        children: std.ArrayListUnmanaged(Indexer) = .{},

        pub fn init(allocator: Allocator) !Self {
            var tags = try std.ArrayListUnmanaged(Tag).initCapacity(allocator, 1);
            tags.appendAssumeCapacity(undefined);
            errdefer tags.deinit(allocator);

            var payloads = try std.ArrayListUnmanaged(Slice).initCapacity(allocator, 1);
            payloads.appendAssumeCapacity(Slice.empty);
            errdefer payloads.deinit(allocator);

            var children = try std.ArrayListUnmanaged(Slice).initCapacity(allocator, 1);
            children.appendAssumeCapacity(Slice.empty);
            errdefer children.deinit(allocator);

            return Self{
                .allocator = allocator,
                .nodes_tag = tags,
                .nodes_payload = payloads,
                .nodes_children = children,
            };
        }

        pub fn deinit(self: *Self) void {
            self.payloads.deinit(self.allocator);
            self.children.deinit(self.allocator);
            self.nodes_tag.deinit(self.allocator);
            self.nodes_payload.deinit(self.allocator);
            self.nodes_children.deinit(self.allocator);
            self.root_children.deinit(self.allocator);
        }

        pub fn consume(self: *Self) !SourceTree(Tag) {
            const alloc = self.allocator;

            const payloads = try self.payloads.toOwnedSlice(alloc);
            errdefer alloc.free(payloads);

            self.nodes_children.items[0] = Slice{
                .offset = @truncate(self.children.items.len),
                .length = @truncate(self.root_children.items.len),
            };
            defer self.root_children.deinit(alloc);
            try self.children.appendSlice(alloc, self.root_children.items);
            const children = try self.children.toOwnedSlice(alloc);
            errdefer alloc.free(children);

            const nodes_tag = try self.nodes_tag.toOwnedSlice(alloc);
            errdefer alloc.free(nodes_tag);

            const nodes_payload = try self.nodes_payload.toOwnedSlice(alloc);
            errdefer alloc.free(nodes_payload);

            const nodes_children = try self.nodes_children.toOwnedSlice(alloc);
            errdefer alloc.free(nodes_children);

            return SourceTree(Tag){
                .payloads = payloads,
                .children = children,
                .nodes_tag = nodes_tag,
                .nodes_payload = nodes_payload,
                .nodes_children = nodes_children,
            };
        }

        pub fn append(self: *Self, tag: Tag) !Node {
            const node = try self.createNodeAuthor(tag);
            errdefer self.dropLastNodeAuthor(node.index);

            try self.root_children.append(self.allocator, node.index);
            return node;
        }

        fn createNodeAuthor(self: *Self, tag: Tag) !Node {
            const index: Indexer = @truncate(self.nodes_tag.items.len);

            try self.nodes_tag.append(self.allocator, tag);
            errdefer _ = self.nodes_tag.pop();

            try self.nodes_payload.append(self.allocator, Slice.empty);
            errdefer _ = self.nodes_payload.pop();

            try self.nodes_children.append(self.allocator, Slice.empty);
            errdefer _ = self.nodes_children.pop();

            return Node{
                .allocator = self.allocator,
                .tree = self,
                .index = index,
            };
        }

        fn dropLastNodeAuthor(self: *Self, index: Indexer) void {
            std.debug.assert(index == self.nodes_tag.items.len - 1);
            errdefer _ = self.nodes_tag.pop();
            errdefer _ = self.nodes_payload.pop();
            errdefer _ = self.nodes_children.pop();
        }

        fn sealNodeAuthor(self: *Self, index: Indexer, payload: Payload, children: []const Indexer) !void {
            const children_len: Indexer = @truncate(children.len);
            const children_offset: Indexer = @truncate(self.children.items.len);
            try self.children.appendSlice(self.allocator, children);
            self.nodes_children.items[index] = Slice{ .offset = children_offset, .length = children_len };
            errdefer {
                self.nodes_children.items[index] = Slice.empty;
                self.children.items.len -= children.len;
                self.children.capacity += children.len;
            }

            switch (payload) {
                .none => {},
                .slice => |slice| self.nodes_payload.items[index] = slice,
                .value => |s| {
                    const offset = self.payloads.items.len;
                    try self.payloads.appendSlice(self.allocator, s);
                    self.nodes_payload.items[index] = Slice{
                        .offset = @truncate(offset),
                        .length = @truncate(s.len),
                    };
                },
            }
        }

        fn formatPayload(self: *Self, comptime format: []const u8, args: anytype) !Payload {
            const offset = self.payloads.items.len;
            try self.payloads.writer(self.allocator).print(format, args);
            return .{ .slice = .{
                .offset = @truncate(offset),
                .length = @truncate(self.payloads.items.len - offset),
            } };
        }

        const Payload = union(enum) {
            none,
            value: []const u8,
            slice: Slice,
        };

        pub const Node = struct {
            allocator: Allocator,
            tree: *Self,
            index: Indexer,
            payload: Payload = .none,
            children: std.ArrayListUnmanaged(Indexer) = .{},

            pub fn deinit(self: *Node) void {
                self.children.deinit(self.allocator);
            }

            pub fn seal(self: *Node) !void {
                try self.tree.sealNodeAuthor(self.index, self.payload, self.children.items);
                self.children.deinit(self.allocator);
            }

            pub fn append(self: *Node, tag: Tag) !Node {
                const node = try self.tree.createNodeAuthor(tag);
                errdefer self.tree.dropLastNodeAuthor(node.index);

                try self.children.append(self.allocator, node.index);
                return node;
            }

            pub fn setPayload(self: *Node, value: []const u8) void {
                std.debug.assert(self.payload == .none);
                self.payload = .{ .value = value };
            }

            pub fn setPayloadFmt(self: *Node, comptime format: []const u8, args: anytype) !Indexer {
                std.debug.assert(self.payload == .none);
                const payload = try self.tree.formatPayload(format, args);
                self.payload = payload;
                return payload.slice.length;
            }
        };
    };
}

test "TreeAuthor" {
    const tree = blk: {
        var author = try SourceTreeAuthor(u8).init(test_alloc);
        errdefer author.deinit();

        var node = try author.append(101);
        errdefer node.deinit();

        var child = try node.append(201);
        errdefer child.deinit();

        child.setPayload("bar");
        try child.seal();

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
fn expectTree(tree: SourceTree(u8)) !void {
    var iter = tree.iterate();
    var node = iter.next().?;
    try testing.expectEqual(101, node.tag);

    var chuld_iter = node.iterate();
    var child = chuld_iter.next().?;
    try testing.expectEqual(201, child.tag);
    try testing.expectEqualStrings("bar", child.payload);
    child = chuld_iter.next().?;
    try testing.expectEqual(202, child.tag);
    try testing.expectEqual(null, chuld_iter.next());

    node = iter.next().?;
    try testing.expectEqual(102, node.tag);
    try testing.expectEqualStrings("foo108", node.payload);
    try testing.expectEqual(null, iter.next());
}
