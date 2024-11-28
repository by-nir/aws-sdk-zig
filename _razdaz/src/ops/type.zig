const std = @import("std");
const std_test = std.testing;
const lib = @import("../combine.zig");
const Operator = lib.Operator;
const Resolver = lib.Resolver;
const MatchVerdict = lib.Matcher.Verdict;
const testing = @import("../testing.zig");
const native_endian = @import("builtin").cpu.arch.endian();

pub const Layout = union(enum) {
    /// Assumes the source is tightly packed with no padding or alignment.
    dense,
    /// Assumes the source is aligned and padded.
    natural,
};

pub const ValueOptions = struct {
    /// The size and alignment of the source.
    layout: Layout = .natural,
    /// The byte endianness of the source.
    endianess: std.builtin.Endian = native_endian,
};

/// Match a value of a given type.
/// Defaults to natural layout and native endianess.
///
/// Options:
/// - `layout`: The size and alignment of the source.
///   - `dense`: Assumes the source is tightly packed with no padding or alignment.
///   - `natural`: Assumes the source is aligned and padded.
/// - `endianess`: The byte endianness of the source.
pub fn typeValue(comptime T: type, comptime options: ValueOptions) Operator {
    comptime var size = switch (options.layout) {
        .dense => LayoutInfo.byteSize(T),
        .natural => LayoutInfo.stride(T),
    };
    if (size == 0) @compileError("unsupported 0-sized type");
    switch (@typeInfo(T)) {
        .array => |meta| {
            if (meta.sentinel) |_| size = meta.len * LayoutInfo.stride(meta.child) - LayoutInfo.padding(T);
        },
        else => {},
    }

    const funcs = struct {
        fn match(i: usize, _: u8) MatchVerdict {
            return if (i == size - 1) .done_include else .next;
        }

        fn resolve(bytes: []const u8) ?T {
            var value = std.mem.bytesToValue(T, bytes);
            toNativeEndian(T, &value, options.endianess);
            return value;
        }
    };

    return Operator.define(funcs.match, .{
        .scratch_hint = .count(size),
        .resolve = Resolver.define(.fail, funcs.resolve),
        .alignment = switch (options.layout) {
            .dense => null,
            .natural => LayoutInfo.alignment(T),
        },
    });
}

test typeValue {
    try testing.expectEvaluate(typeValue(u8, .{}), &.{ 101, 102, 103, 104 }, 101, 1);

    try testing.expectEvaluate(typeValue(u16, .{
        .endianess = native_endian,
    }), std.mem.toBytes(@as(u16, 0xFF)) ++ &[1]u8{108}, 0xFF, 2);

    try testing.expectEvaluate(typeValue(u16, .{
        .endianess = switch (native_endian) {
            .little => .big,
            .big => .little,
        },
    }), std.mem.toBytes(@as(u16, 0xFF)) ++ &[1]u8{108}, 0xFF00, 2);

    try testing.expectEvaluate(typeValue(u24, .{
        .layout = .dense,
    }), &.{ 0xFF, 0x00, 0xFF, 104, 105 }, 0xFF00FF, 3);

    try testing.expectEvaluate(typeValue(u24, .{
        .layout = .natural,
    }), std.mem.toBytes(@as(u24, 0xFF)) ++ &[1]u8{108}, 0xFF, 4);

    try testing.expectStreamError(typeValue(u24, .{
        .layout = .natural,
    }), &.{ 0, 0, 0 });
}

fn toNativeEndian(comptime Value: type, value: *Value, endianess: std.builtin.Endian) void {
    switch (@typeInfo(Value)) {
        .bool => {},
        .int => value.* = std.mem.toNative(Value, value.*, endianess),
        .float => |meta| {
            const Int = std.meta.Int(.unsigned, meta.bits);
            const int = std.mem.toNative(Int, @bitCast(value.*), endianess);
            value.* = @bitCast(int);
        },
        .@"enum" => |meta| {
            const swap = std.mem.toNative(meta.tag_type, @intFromEnum(value.*), endianess);
            value.* = @enumFromInt(swap);
        },
        .array => |meta| {
            if (!childHasEndianess(meta.child)) return;
            for (value) |*item| toNativeEndian(meta.child, item, endianess);
        },
        .vector => |meta| toNativeEndian([meta.len]meta.child, @ptrCast(value), endianess),
        .@"struct" => |meta| {
            inline for (meta.fields) |f| {
                if (comptime !childHasEndianess(f.type)) continue;
                var field_value = @field(value, f.name);
                toNativeEndian(f.type, &field_value, endianess);
                @field(value, f.name) = field_value;
            }
        },
        else => @compileError("unsupported type"),
    }
}

test toNativeEndian {
    const other_endian = switch (native_endian) {
        .little => .big,
        .big => .little,
    };

    {
        var val: bool = true;
        toNativeEndian(bool, &val, other_endian);
        try std_test.expectEqual(true, val);
    }

    {
        var val: u32 = 0xFFFF;
        toNativeEndian(u32, &val, other_endian);
        try std_test.expectEqual(0xFFFF0000, val);
    }

    {
        var val: f32 = @bitCast(@as(u32, 0xFFFF));
        toNativeEndian(f32, &val, other_endian);
        try std_test.expectEqual(0xFFFF0000, @as(u32, @bitCast(val)));
    }

    {
        const Enum = enum(u16) {
            foo = 0xFF,
            bar = 0xFF00,
        };

        var val: Enum = .foo;
        toNativeEndian(Enum, &val, other_endian);
        try std_test.expectEqual(.bar, val);
    }

    {
        var val: [2]u16 = .{ 0x11, 0x22 };
        toNativeEndian([2]u16, &val, other_endian);
        try std_test.expectEqual([2]u16{ 0x1100, 0x2200 }, val);
    }

    {
        var val: @Vector(2, u16) = .{ 0x11, 0x22 };
        toNativeEndian(@Vector(2, u16), &val, other_endian);
        try std_test.expectEqual(@Vector(2, u16){ 0x1100, 0x2200 }, val);
    }

    {
        const Struct = packed struct {
            foo: bool,
            bar: u16,
        };

        var val: Struct = .{ .foo = true, .bar = 0xFF };
        toNativeEndian(Struct, &val, other_endian);
        try std_test.expectEqual(Struct{ .foo = true, .bar = 0xFF00 }, val);
    }
}

fn childHasEndianess(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .bool => return false,
        .int, .float, .@"enum" => return true,
        .array, .vector => |meta| return childHasEndianess(meta.child),
        .@"struct" => |meta| switch (meta.layout) {
            .@"packed" => {
                inline for (meta.fields) |field| {
                    if (childHasEndianess(field.type)) return true;
                } else {
                    return false;
                }
            },
            else => @compileError("unsupported struct layout"),
        },
        else => @compileError("unsupported child type"),
    }
}

const LayoutInfo = struct {
    pub fn stride(comptime T: type) comptime_int {
        return @sizeOf(T);
    }

    pub fn alignment(comptime T: type) comptime_int {
        return @alignOf(T);
    }

    pub fn bitSize(comptime T: type) comptime_int {
        return @bitSizeOf(T);
    }

    pub fn byteSize(comptime T: type) comptime_int {
        return (@bitSizeOf(T) + 7) / 8;
    }

    pub fn padding(comptime T: type) comptime_int {
        return @sizeOf(T) - (@bitSizeOf(T) + 7) / 8;
    }
};

test LayoutInfo {
    try std_test.expectEqual(4, LayoutInfo.stride(u24));
    try std_test.expectEqual(4, LayoutInfo.alignment([2]u24));
    try std_test.expectEqual(24, LayoutInfo.bitSize(u24));
    try std_test.expectEqual(3, LayoutInfo.byteSize(u24));
    try std_test.expectEqual(1, LayoutInfo.padding(u24));
}
