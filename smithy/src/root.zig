pub const Pipeline = @import("Pipeline.zig");

const parse = @import("parse.zig");
pub const ParsePolicy = parse.Policy;

const codegen = @import("codegen.zig");
pub const GenerateHooks = codegen.Hooks;
pub const GeneratePolicy = codegen.Policy;
pub const codegen_zig = @import("codegen/zig.zig");
pub const codegen_md = @import("codegen/md.zig");

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
    _ = codegen_md;
    _ = codegen_zig;
    _ = codegen;

    // Pipeline
    _ = Pipeline;
}
