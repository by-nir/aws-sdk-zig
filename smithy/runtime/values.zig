const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const testing = std.testing;

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/substring.rs
pub fn substring(value: []const u8, start: usize, end: usize, reverse: bool) ![]const u8 {
    if (start >= end) return error.InvalidRange;
    if (end > value.len) return error.RangeOutOfBounds;
    for (value) |c| if (!ascii.isASCII(c)) return error.InvalidAscii;

    return if (reverse)
        value[value.len - end .. value.len - start]
    else
        value[start..end];
}

test "substring" {
    try testing.expectEqualStrings("he", try substring("hello", 0, 2, false));
    try testing.expectEqualStrings("hello", try substring("hello", 0, 5, false));
    try testing.expectError(error.InvalidRange, substring("hello", 0, 0, false));
    try testing.expectError(error.RangeOutOfBounds, substring("hello", 0, 6, false));

    try testing.expectEqualStrings("lo", try substring("hello", 0, 2, true));
    try testing.expectEqualStrings("hello", try substring("hello", 0, 5, true));
    try testing.expectError(error.InvalidRange, substring("hello", 0, 0, true));

    try testing.expectError(error.InvalidAscii, substring("a🐱b", 0, 2, false));
}

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

    pub const KV = struct {
        key: []const u8,
        key_alloc: bool,
        document: Document,

        pub fn deinit(self: KV, allocator: Allocator) void {
            if (self.key_alloc) allocator.free(self.key);
            self.document.deinit(allocator);
        }
    };
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
