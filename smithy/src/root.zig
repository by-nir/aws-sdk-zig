pub const Pipeline = @import("Pipeline.zig");

const Parser = @import("parse/Parser.zig");
pub const ParsePolicy = Parser.Policy;

const Generator = @import("codegen/Generator.zig");
pub const GenerateHooks = Generator.Hooks;
pub const GeneratePolicy = Generator.Policy;
pub const codegen_zig = @import("codegen/zig.zig");
pub const codegen_md = @import("codegen/md.zig");

const symbols = @import("systems/symbols.zig");
pub usingnamespace symbols;

const traits = @import("systems/traits.zig");
pub const TraitsRegistry = traits.TraitsRegistry;

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
    _ = symbols;
    _ = traits;
    _ = @import("prelude.zig");

    // Parse
    _ = @import("parse/Model.zig");
    _ = Parser;

    // Codegen
    _ = @import("codegen/CodegenWriter.zig");
    _ = codegen_md;
    _ = codegen_zig;
    _ = Generator;

    // Pipeline
    _ = Pipeline;
}
