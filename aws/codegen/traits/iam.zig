//! IAM Policy Traits are used to describe the permission structure of a service
//! in relation to AWS IAM. Services integrated with AWS IAM define resource types,
//! actions, and condition keys that IAM users can use to construct IAM policies.
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/aws-iam.html#aws-iam-traits)
const smithy = @import("smithy/codegen");
const TraitsRegistry = smithy.TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // aws.iam#actionName
    // aws.iam#actionPermissionDescription
    // aws.iam#conditionKeyValue
    // aws.iam#conditionKeys
    // aws.iam#defineConditionKeys
    // aws.iam#disableConditionKeyInference
    // aws.iam#iamAction
    // aws.iam#iamResource
    // aws.iam#requiredActions
    // aws.iam#serviceResolvedConditionKeys
    // aws.iam#supportedPrincipalTypes
};
