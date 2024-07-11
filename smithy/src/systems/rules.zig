const model = @import("rules/model.zig");
pub const Rule = model.Rule;
pub const RuleSet = model.RuleSet;
pub const ArgValue = model.ArgValue;
pub const Parameter = model.Parameter;
pub const StringKV = model.StringKV;

const parsing = @import("rules/parsing.zig");
pub const parse = parsing.parse;

const library = @import("rules/library.zig");
pub const BuiltIn = library.BuiltIn;
pub const Function = library.Function;
pub const BuiltInsRegistry = library.BuiltInsRegistry;
pub const FunctionsRegistry = library.FunctionsRegistry;

pub const RulesEngine = @import("rules/RulesEngine.zig");
pub const Generator = @import("rules/Generator.zig");

test {
    _ = model;
    _ = parsing;
    _ = library;
    _ = RulesEngine;
    _ = Generator;
}
