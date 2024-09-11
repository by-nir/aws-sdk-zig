pub const config = @import("config.zig");

const prelude = @import("prelude.zig");
pub const traits = prelude.traits;

const smithy = @import("jobs/smithy.zig");
pub const SmithyTask = smithy.Smithy;
pub const SmithyOptions = smithy.SmithyOptions;
pub const ServicePolicy = smithy.ServicePolicy;
pub const ServiceFilterHook = smithy.ServiceFilterHook;

const smithy_parse = @import("jobs/smithy_parse.zig");
pub const ParsePolicy = smithy_parse.ParsePolicy;

const smithy_codegen = @import("jobs/smithy_codegen.zig");
pub const CodegenPolicy = smithy_codegen.CodegenPolicy;
pub const ReadmeMetadata = smithy_codegen.ReadmeMetadata;
pub const ScriptHeadHook = smithy_codegen.ScriptHeadHook;
pub const ServiceReadmeHook = smithy_codegen.ServiceReadmeHook;
pub const ExtendClientScriptHook = smithy_codegen.ExtendClientScriptHook;
pub const ExtendEndpointScriptHook = smithy_codegen.ExtendEndpointScriptHook;

const smithy_codegen_shape = @import("jobs/smithy_codegen_shape.zig");
pub const OperationShape = smithy_codegen_shape.OperationShape;
pub const ServiceAuthSchemesHook = smithy_codegen_shape.ServiceAuthSchemesHook;
pub const ServiceHeadHook = smithy_codegen_shape.ServiceHeadHook;
pub const ResourceHeadHook = smithy_codegen_shape.ResourceHeadHook;
pub const OperationShapeHook = smithy_codegen_shape.OperationShapeHook;

const syb = @import("systems/symbols.zig");
pub usingnamespace syb;

const trt = @import("systems/traits.zig");
pub const StringTrait = trt.StringTrait;
pub const TraitsRegistry = trt.TraitsRegistry;

const rls = @import("systems/rules.zig");
pub const RuleSet = rls.RuleSet;
pub const RulesFunc = rls.Function;
pub const RulesBuiltIn = rls.BuiltIn;
pub const RulesGenerator = rls.Generator;
pub const RulesArgValue = rls.ArgValue;
pub const RulesFuncsRegistry = rls.FunctionsRegistry;
pub const RulesBuiltInsRegistry = rls.BuiltInsRegistry;
pub const RulesParamKV = rls.StringKV(rls.Parameter);

const IssuesBag = @import("utils/IssuesBag.zig");
pub const PolicyResolution = IssuesBag.PolicyResolution;

pub const JsonReader = @import("utils/JsonReader.zig");
pub const name_util = @import("utils/names.zig");

test {
    // Utils
    _ = name_util;
    _ = IssuesBag;
    _ = JsonReader;

    // Systems
    _ = syb;
    _ = trt;
    _ = rls;

    // Jobs
    _ = smithy_codegen_shape;
    _ = smithy_codegen;
    _ = smithy_parse;
    _ = smithy;

    _ = prelude;
}
