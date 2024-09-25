const std = @import("std");
const Allocator = std.mem.Allocator;
const Delegate = @import("jobz").Delegate;
const smithy = @import("smithy/codegen");
const SymbolsProvider = smithy.SymbolsProvider;
const ServiceExtension = smithy.ServiceExtension;

pub fn extendCommonErrors(self: *const Delegate, _: *SymbolsProvider, extension: *ServiceExtension) !void {
    const arena = self.alloc();

    try extension.appendError(try buildError(
        arena,
        "AccessDeniedException",
        .bad_request,
        "<p>You do not have sufficient access to perform this action.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "IncompleteSignature",
        .bad_request,
        "<p>The request signature does not conform to AWS standards.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "InternalFailure",
        .internal_server_error,
        "<p>The request processing has failed because of an unknown error, exception or failure.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "InvalidAction",
        .bad_request,
        "<p>The action or operation requested is invalid. Verify that the action is typed correctly.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "InvalidClientTokenId",
        .forbidden,
        "<p>The X.509 certificate or AWS access key ID provided does not exist in our records.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "NotAuthorized",
        .bad_request,
        "<p>You do not have permission to perform this action.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "OptInRequired",
        .forbidden,
        "<p>The AWS access key ID needs a subscription for the service.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "RequestExpired",
        .bad_request,
        "<p>The request reached the service more than 15 minutes after the date stamp on the request or more than 15 minutes after the request expiration date (such as for pre-signed URLs), or the date stamp on the request is more than 15 minutes in the future.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "ServiceUnavailable",
        .service_unavailable,
        "<p>The request has failed due to a temporary failure of the server.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "ThrottlingException",
        .bad_request,
        "<p>The request was denied due to request throttling.</p>",
    ));

    try extension.appendError(try buildError(
        arena,
        "ValidationError",
        .bad_request,
        "<p>The input fails to satisfy the constraints specified by an AWS service.</p>",
    ));
}

fn buildError(
    arena: Allocator,
    name: []const u8,
    http_status: std.http.Status,
    html_docs: []const u8,
) !SymbolsProvider.Error {
    return .{
        .id = null,
        .name_api = name,
        .name_field = try smithy.name_util.formatCase(arena, .snake, name),
        .retryable = false,
        .http_status = http_status,
        .source = .server,
        .html_docs = html_docs,
    };
}
