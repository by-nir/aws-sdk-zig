//! CloudFormation traits are used to describe Smithy resources and their components
//! so they can be converted to [CloudFormation Resource Schemas](https://docs.aws.amazon.com/cloudformation-cli/latest/userguide/resource-type-schema.html).
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/aws-cloudformation.html#aws-cloudformation-traits)
const smithy = @import("smithy/codegen");
const TraitsRegistry = smithy.TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // aws.cloudformation#cfnAdditionalIdentifier
    // aws.cloudformation#cfnDefaultValue
    // aws.cloudformation#cfnExcludeProperty
    // aws.cloudformation#cfnMutability
    // aws.cloudformation#cfnName
    // aws.cloudformation#cfnResource
};
