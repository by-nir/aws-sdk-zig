//! Smithy can integrate with Amazon API Gateway using traits, authentication
//! schemes, and OpenAPI specifications.
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/amazon-apigateway.html#amazon-api-gateway-traits)
const smithy = @import("smithy/codegen");
const TraitsRegistry = smithy.TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // aws.apigateway#apiKeySource
    // aws.apigateway#authorizer
    // aws.apigateway#authorizers
    // aws.apigateway#integration
    // aws.apigateway#mockIntegration
    // aws.apigateway#requestValidator
};
