const IssueBehavior = @import("../systems/issues.zig").IssueBehavior;

pub const ParseBehavior = struct {
    property: IssueBehavior = .abort,
    trait: IssueBehavior = .abort,
};
