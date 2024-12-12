const std = @import("std");
const mvzr = @import("mvzr");

const base_format = "Field `{s}.{s}` ";
pub const Error = error{InvalidOperationInput};

pub fn valueRange(
    comptime service: @Type(.enum_literal),
    container: []const u8,
    field: []const u8,
    comptime T: type,
    min: ?T,
    max: ?T,
    value: T,
) !void {
    const log = std.log.scoped(service);

    if (min) |d| if (value < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "value is less than {d}", .{ container, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (value > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "value is more than {d}", .{ container, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn collectionLength(
    comptime service: @Type(.enum_literal),
    container: []const u8,
    field: []const u8,
    min: ?usize,
    max: ?usize,
    count: usize,
) !void {
    const log = std.log.scoped(service);

    if (min) |d| if (count < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "has less than {d} items", .{ container, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (count > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "has more than {d} items", .{ container, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn bytesLength(
    comptime service: @Type(.enum_literal),
    container: []const u8,
    field: []const u8,
    min: ?usize,
    max: ?usize,
    size: usize,
) !void {
    const log = std.log.scoped(service);

    if (min) |d| if (size < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "size is less than {d} bytes", .{ container, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (size > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "size is more than {d} bytes", .{ container, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn stringLength(
    comptime service: @Type(.enum_literal),
    container: []const u8,
    field: []const u8,
    min: ?usize,
    max: ?usize,
    s: []const u8,
) !void {
    const log = std.log.scoped(service);
    const len = try std.unicode.utf8CountCodepoints(s);

    if (min) |d| if (len < d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "length is less than {d} characters", .{ container, field, d });
        return Error.InvalidOperationInput;
    };

    if (max) |d| if (len > d) {
        @branchHint(.unlikely);
        log.err(base_format ++ "length is more than {d} characters", .{ container, field, d });
        return Error.InvalidOperationInput;
    };
}

pub fn stringPattern(
    comptime service: @Type(.enum_literal),
    container: []const u8,
    field: []const u8,
    comptime pattern: []const u8,
    s: []const u8,
) !void {
    const log = std.log.scoped(service);
    const regex = comptime mvzr.compile(pattern) orelse unreachable;
    if (!regex.isMatch(s)) {
        @branchHint(.unlikely);
        log.err(base_format ++ "does not match pattern \"{s}\"", .{ container, field, pattern });
        return Error.InvalidOperationInput;
    }
}
