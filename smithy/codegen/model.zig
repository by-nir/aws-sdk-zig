pub const prelude = @import("model/prelude.zig");

const id = @import("model/smithy_id.zig");
pub const SmithyId = id.SmithyId;

const typ = @import("model/smithy_type.zig");
pub const SmithyType = typ.SmithyType;

const meta = @import("model/meta.zig");
pub const SmithyMeta = meta.SmithyMeta;

const srvc = @import("model/service.zig");
pub const SmithyService = srvc.SmithyService;
pub const SmithyResource = srvc.SmithyResource;
pub const SmithyOperation = srvc.SmithyOperation;

const mapping = @import("model/mapping.zig");
pub const SmithyTaggedValue = mapping.SmithyTaggedValue;
pub const SmithyRefMapValue = mapping.SmithyRefMapValue;

test {
    _ = prelude;
    _ = mapping;
    _ = id;
    _ = typ;
    _ = meta;
    _ = srvc;
}
