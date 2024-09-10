const std = @import("std");
const Response = @import("smithy/runtime").Response;
const Operation = @import("../http.zig").Operation;

/// Caller owns the returned memory.
pub fn inputJson10(op: *Operation, target: []const u8, input: anytype, comptime in_flds: anytype) ![]const u8 {
    const req = &op.request;
    try req.headers.put(op.allocator, "x-amz-target", target);
    try req.headers.put(op.allocator, "content-type", "application/x-amz-json-1.0");

    const payload = try std.json.stringifyAlloc(op.allocator, input, .{});
    req.payload = payload;
    return payload;
}

pub fn outputJson10(op: *Operation, comptime Out: type, comptime Err: type, comptime out_flds: anytype, comptime err_flds: anytype) !Response(Out, Err) {
    const rsp = op.response orelse return error.MissingResponse;

    std.debug.print(">> {}\n{s}\n{s}\n", .{ rsp.status, rsp.headers, rsp.body });
    return undefined;
}
