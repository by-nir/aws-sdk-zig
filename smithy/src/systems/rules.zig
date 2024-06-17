const model = @import("rules/model.zig");
pub const RuleSet = model.RuleSet;

const parsing = @import("rules/parsing.zig");
pub const parse = parsing.parse;

pub const RulesEngine = @import("rules/RulesEngine.zig");

test {
    _ = model;
    _ = parsing;
    _ = RulesEngine;
}
