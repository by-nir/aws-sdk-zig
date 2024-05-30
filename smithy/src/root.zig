pub const Pipeline = @import("Pipeline.zig");

const parse = @import("parse.zig");
pub const ParsePolicy = parse.Policy;

const codegen = @import("codegen.zig");
pub const GenerateHooks = codegen.Hooks;
pub const GeneratePolicy = codegen.Policy;
pub const Script = @import("codegen/Zig.zig");
pub const Markdown = @import("codegen/Markdown.zig");

const syb_id = @import("symbols/identity.zig");
pub usingnamespace syb_id;

const syb_shapes = @import("symbols/shapes.zig");
pub usingnamespace syb_shapes;

const syb_traits = @import("symbols/traits.zig");
pub const TraitsRegistry = syb_traits.TraitsRegistry;

const IssuesBag = @import("utils/IssuesBag.zig");
pub const PolicyResolution = IssuesBag.PolicyResolution;

pub const JsonReader = @import("utils/JsonReader.zig");

test {
    // Utils
    _ = @import("utils/names.zig");
    _ = @import("utils/declarative.zig");
    _ = IssuesBag;
    _ = JsonReader;

    // Systems
    _ = syb_id;
    _ = syb_traits;
    _ = syb_shapes;
    _ = @import("prelude.zig");

    // Parse
    _ = parse;

    // Codegen
    _ = @import("codegen/CodegenWriter.zig");
    _ = @import("codegen/zig/flow.zig");
    _ = @import("codegen/zig/expr.zig");
    _ = @import("codegen/zig/scope.zig");
    _ = @import("codegen/StackWriter.zig");
    _ = Markdown;
    _ = Script;
    _ = codegen;

    // Pipeline
    _ = Pipeline;
}
