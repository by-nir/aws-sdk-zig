pub const config = @import("config.zig");

pub const pipez = @import("pipeline/root.zig");
pub const files_tasks = @import("tasks/files.zig");
pub const codegen_tasks = @import("tasks/codegen.zig");
pub const codegen_md = @import("codegen/md.zig");
pub const codegen_zig = @import("codegen/zig.zig");

const prelude = @import("prelude.zig");
pub const traits = prelude.traits;

const smithy = @import("tasks/smithy.zig");
pub const SmithyTask = smithy.Smithy;
pub const SmithyOptions = smithy.SmithyOptions;
pub const ServicePolicy = smithy.ServicePolicy;
pub const ReadmeMetadata = smithy.ReadmeMetadata;
pub const ServiceFilterHook = smithy.ServiceFilterHook;
pub const ScriptCodegenHeadHook = smithy.ScriptCodegenHeadHook;
pub const ServiceCodegenReadmeHook = smithy.ServiceCodegenReadmeHook;

const smithy_parse = @import("tasks/smithy_parse.zig");
pub const ParsePolicy = smithy_parse.ParsePolicy;

const smithy_codegen = @import("tasks/smithy_codegen.zig");
pub const CodegenPolicy = smithy_codegen.CodegenPolicy;
pub const ErrorShape = smithy_codegen.ErrorShape;
pub const OperationShape = smithy_codegen.OperationShape;
pub const ClientScriptHeadHook = smithy_codegen.ClientScriptHeadHook;
pub const ServiceHeadHook = smithy_codegen.ServiceHeadHook;
pub const ResourceHeadHook = smithy_codegen.ResourceHeadHook;
pub const ErrorShapeHook = smithy_codegen.ErrorShapeHook;
pub const OperationTypeHook = smithy_codegen.OperationTypeHook;
pub const OperationShapeHook = smithy_codegen.OperationShapeHook;
pub const UniqueListTypeHook = smithy_codegen.UniqueListTypeHook;

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

    // Codegen
    _ = @import("codegen/CodegenWriter.zig");
    _ = codegen_md;
    _ = codegen_zig;

    // Tasks
    _ = files_tasks;
    _ = codegen_tasks;
    _ = smithy_parse;
    _ = smithy_codegen;
    _ = smithy;

    _ = pipez;
    _ = prelude;
}
