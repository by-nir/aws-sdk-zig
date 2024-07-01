pub const config = @import("config.zig");

pub const Pipeline = @import("Pipeline.zig");

const Parser = @import("parse/Parser.zig");
pub const ParsePolicy = Parser.Policy;

const Generator = @import("codegen/Generator.zig");
pub const GenerateHooks = Generator.Hooks;
pub const GeneratePolicy = Generator.Policy;

const script = @import("codegen/script.zig");
pub const Script = script.Script;
pub const ScriptLang = script.ScriptLang;
pub const ScriptAlloc = script.ScriptAlloc;
pub const codegen_md = @import("codegen/md.zig");
pub const codegen_zig = @import("codegen/zig.zig");

const syb = @import("systems/symbols.zig");
pub usingnamespace syb;

const trt = @import("systems/traits.zig");
pub const TraitsRegistry = trt.TraitsRegistry;

const rls = @import("systems/rules.zig");
pub const RulesEngine = rls.RulesEngine;
pub const RulesFunc = rls.Function;
pub const RulesBuiltIn = rls.BuiltIn;
pub const RulesGenerator = rls.Generator;
pub const RulesArgValue = rls.ArgValue;
pub const RulesFuncsRegistry = rls.FunctionsRegistry;
pub const RulesBuiltInsRegistry = rls.BuiltInsRegistry;

const prelude = @import("prelude.zig");
pub const traits = prelude.traits;

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
    _ = syb;
    _ = trt;
    _ = rls;

    // Parse
    _ = @import("parse/Model.zig");
    _ = Parser;

    // Codegen
    _ = @import("codegen/CodegenWriter.zig");
    _ = codegen_md;
    _ = codegen_zig;
    _ = script;
    _ = Generator;

    // Pipeline
    _ = prelude;
    _ = Pipeline;
    _ = @import("pipeline/utils.zig");
    _ = @import("pipeline/task.zig");
    _ = @import("pipeline/invoke.zig");
    _ = @import("pipeline/scope.zig");
    _ = @import("pipeline/schedule.zig");
    _ = @import("pipeline/pipeline.zig");
}
