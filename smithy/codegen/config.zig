/// Name of the allocator identifier
pub const alloc_param = "allocator";

/// Name of the stack allocator identifier
pub const stack_alloc = "scratch_alloc";

/// Service client type name
pub const service_client_type = "Client";

/// Runtime public scope
pub const scope_public = "smithy";

/// Runtime private scope
pub const scope_private = scope_public ++ "._private_";

/// Endpoint scope
pub const endpoint_scope = "srvc_endpoint";

/// Endpoint scope filename
pub const endpoint_filename = "endpoint.zig";

/// Endpoint configuration type name
pub const endpoint_config_type = "EndpointConfig";

/// Endpoint resolve function identifier
pub const endpoint_resolve_fn = "resolve";

/// Named types scope
pub const types_scope = "srvc_types";

/// Named types scope filename
pub const types_filename = "data_types.zig";

/// Operations directory name
pub const dir_operations = "operation";
