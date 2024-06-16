const model = @import("rules/model.zig");
pub const RuleSet = model.RuleSet;

const parsing = @import("rules/parsing.zig");
pub const parse = parsing.parse;

pub const RulesEngine = @import("rules/model.zig");

test {
    _ = model;
    _ = parsing;
    _ = @import("rules/library.zig");
    _ = RulesEngine;
}
