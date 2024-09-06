//! https://github.com/awslabs/aws-c-auth

pub const ID_LEN = 20;
pub const SECRET_LEN = 40;

pub const TEST_ID: []const u8 = "AKIAIOSFODNN7EXAMPLE";
pub const TEST_SECRET: []const u8 = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
pub const TEST_CREDS = Credentials{ .access_id = TEST_ID, .access_secret = TEST_SECRET };

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html)
pub const Credentials = struct {
    /// The access key ID.
    access_id: []const u8,
    /// The secret access key.
    access_secret: []const u8,
    /// The session token (optional).
    session_token: ?[]const u8 = null,

    pub fn validSlicesLength(self: Credentials) bool {
        return self.access_id.len == ID_LEN and self.access_secret.len == SECRET_LEN;
    }
};
