pub const Pipeline = @import("Pipeline.zig");

const parse = @import("parse.zig");
pub const ParsePolicy = parse.Policy;

const generate = @import("generate.zig");
pub const GenerateHooks = generate.Hooks;
pub const GeneratePolicy = generate.Policy;

pub const Script = @import("generate/Zig.zig");
pub const Markdown = @import("generate/Markdown.zig");

const syb_id = @import("symbols/identity.zig");
pub usingnamespace syb_id;

const syb_shapes = @import("symbols/shapes.zig");
pub usingnamespace syb_shapes;

const syb_traits = @import("symbols/traits.zig");
pub const TraitsRegistry = syb_traits.TraitsRegistry;

const IssuesBag = @import("utils/IssuesBag.zig");
pub const PolicyResolution = IssuesBag.PolicyResolution;

pub const JsonReader = @import("utils/JsonReader.zig");

const specs = @import("specs.zig");
pub const RulesEngine = specs.RulesEngine;

test {
    _ = @import("utils/names.zig");
    _ = IssuesBag;
    _ = JsonReader;
    _ = @import("utils/StackWriter.zig");
    _ = syb_id;
    _ = syb_traits;
    _ = syb_shapes;
    _ = @import("prelude.zig");
    _ = specs;
    _ = parse;
    _ = generate;
    _ = Markdown;
    _ = Script;
    _ = Pipeline;
}
