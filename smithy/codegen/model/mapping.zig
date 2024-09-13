const SmithyId = @import("smithy_id.zig").SmithyId;

pub const SmithyTaggedValue = struct {
    id: SmithyId,
    value: ?*const anyopaque,
};

pub const SmithyRefMapValue = struct {
    name: []const u8,
    shape: SmithyId,
};
