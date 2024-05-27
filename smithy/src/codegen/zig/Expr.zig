const StackChain = @import("../../utils/declarative.zig").StackChain;
const Writer = @import("../CodegenWriter.zig");

const Self = @This();

value: []const u8,

pub fn __write(self: *const Self, writer: *Writer) !void {
    try writer.appendString(self.value);
}

pub fn raw(value: []const u8) Self {
    return .{ .value = value };
}

test "raw" {
    try Writer.expect("foo", raw("foo"));
}
