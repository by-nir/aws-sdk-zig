const std = @import("std");

pub const Error = error{InvalidOperationInput};
const base_format = "Field `{s}.{s}` ";

pub fn valueRange(
    comptime service: @Type(.enum_literal),
    operation: []const u8,
    field: []const u8,
    comptime T: type,
    min: ?T,
    max: ?T,
    value: T,
) !void {
    const log = std.log.scoped(service);

    if (min) |d| if (value < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "value is less than {d}", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (value > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "value is more than {d}", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn collectionLength(
    comptime service: @Type(.enum_literal),
    operation: []const u8,
    field: []const u8,
    min: ?usize,
    max: ?usize,
    count: usize,
) !void {
    const log = std.log.scoped(service);

    if (min) |d| if (count < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "has less than {d} items", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (count > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "has more than {d} items", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn bytesLength(
    comptime service: @Type(.enum_literal),
    operation: []const u8,
    field: []const u8,
    min: ?usize,
    max: ?usize,
    size: usize,
) !void {
    const log = std.log.scoped(service);

    if (min) |d| if (size < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "size is less than {d} bytes", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (size > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "size is more than {d} bytes", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn stringLength(
    comptime service: @Type(.enum_literal),
    operation: []const u8,
    field: []const u8,
    min: ?usize,
    max: ?usize,
    s: []const u8,
) !void {
    const log = std.log.scoped(service);
    const len = try std.unicode.utf8CountCodepoints(s);

    if (min) |d| if (len < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "length is less than {d} characters", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (len > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "length is more than {d} characters", .{ operation, field, d });
        return Error.InvalidOperationInput;
    };
}
