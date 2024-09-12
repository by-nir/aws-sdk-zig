const IssueBehavior = @import("../systems/issues.zig").IssueBehavior;

pub const CodegenBehavior = struct {
    unknown_shape: IssueBehavior = .abort,
    invalid_root: IssueBehavior = .abort,
    shape_codegen_fail: IssueBehavior = .abort,
};
