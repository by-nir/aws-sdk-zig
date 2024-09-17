const smithy = @import("smithy/codegen").config;

/// Name of the allocator identifier
pub const alloc_param = smithy.alloc_param;

/// Name of the stack allocator identifier
pub const stack_alloc = smithy.stack_alloc;

/// Endpoint configuration type name
pub const endpoint_config_type = smithy.endpoint_config_type;

/// Service client type name
pub const service_client_type = smithy.service_client_type;

/// Smithy runtime scope
pub const scope_smithy = smithy.runtime_scope;

/// Endpoint scope
pub const endpoint_scope = smithy.endpoint_scope;

/// Endpoint scope filename
pub const endpoint_filename = smithy.endpoint_filename;

/// Public SDK runtime scope
pub const scope_runtime = "aws_runtime";

/// Private SDK runtime scope
pub const scope_private = "aws_private";

/// SDK auth schemes scope
pub const scope_auth = "aws_auth";

/// SDK http protocols scope
pub const scope_protocol = "aws_protocol";

/// Operation parameter identifier
pub const send_op_param = "operation";

/// Input parameter identifier
pub const send_input_param = "input";

/// Endpoint parameter identifier
pub const send_endpoint_param = "endpoint";
