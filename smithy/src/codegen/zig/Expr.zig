const StackChain = @import("../../utils/declarative.zig").StackChain;
const CodegenWriter = @import("../CodegenWriter.zig");

const Self = @This();

value: []const u8,

pub fn __write(self: *const Self, writer: *CodegenWriter) !void {
    try writer.appendString(self.value);
}

pub fn raw(value: []const u8) Self {
    return .{ .value = value };
}

test "raw" {
    try CodegenWriter.expect("foo", raw("foo"));
}
