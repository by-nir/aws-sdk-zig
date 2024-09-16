const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Document = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    string_alloc: []const u8,
    array: []const Document,
    array_alloc: []const Document,
    object: []const KV,
    object_alloc: []const KV,

    pub const KV = struct {
        key: []const u8,
        key_alloc: bool,
        document: Document,

        pub fn deinit(self: KV, allocator: Allocator) void {
            if (self.key_alloc) allocator.free(self.key);
            self.document.deinit(allocator);
        }
    };

    pub fn deinit(self: Document, allocator: Allocator) void {
        switch (self) {
            .string_alloc => |s| allocator.free(s),
            inline .array, .object => |scope| {
                for (scope) |item| item.deinit(allocator);
            },
            inline .array_alloc, .object_alloc => |scope| {
                for (scope) |item| item.deinit(allocator);
                allocator.free(scope);
            },
            else => {},
        }
    }

    pub fn getString(self: Document) []const u8 {
        return switch (self) {
            .string, .string_alloc => |s| s,
            else => unreachable,
        };
    }

    pub fn getArray(self: Document) []const Document {
        return switch (self) {
            .array, .array_alloc => |s| s,
            else => unreachable,
        };
    }

    pub fn getObject(self: Document) []const KV {
        return switch (self) {
            .object, .object_alloc => |s| s,
            else => unreachable,
        };
    }
};

test "Document.deinit" {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .never_unmap = true,
        .retain_metadata = true,
    }) = .{};
    const alloc = gpa.allocator();

    const ary_alloc = try alloc.alloc(Document, 3);
    ary_alloc[0] = Document{ .boolean = true };
    ary_alloc[1] = Document{ .integer = 108 };
    ary_alloc[2] = Document{ .float = 1.08 };

    const obj_alloc = try alloc.alloc(Document.KV, 2);
    obj_alloc[0] = Document.KV{
        .key = try alloc.dupe(u8, "null"),
        .key_alloc = true,
        .document = Document.null,
    };
    obj_alloc[1] = Document.KV{
        .key = "obj",
        .key_alloc = false,
        .document = .{ .object = &.{
            Document.KV{
                .key = "ary",
                .key_alloc = false,
                .document = Document{ .array = &.{
                    Document{ .string = "str" },
                    Document{ .string_alloc = try alloc.dupe(u8, "str_alloc") },
                } },
            },
            Document.KV{
                .key = "ary_alloc",
                .key_alloc = false,
                .document = Document{ .array_alloc = ary_alloc },
            },
        } },
    };

    const doc = Document{ .object_alloc = obj_alloc };
    doc.deinit(alloc);

    try testing.expectEqual(.ok, gpa.deinit());
}
