//! Compile-time constants: API endpoints, OAuth configuration, request headers.
//! Ports `Monet/Utilities/Constants.swift`.

pub mod api {
    pub const USAGE_ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
    pub const AUTHORIZATION_ENDPOINT: &str = "https://claude.ai/oauth/authorize";
    pub const TOKEN_ENDPOINT: &str = "https://platform.claude.com/v1/oauth/token";
}

pub mod oauth {
    /// Claude Code's public OAuth client id — public by design (it is Claude Code's own).
    pub const CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
    /// Scope required by the usage endpoint.
    pub const SCOPES: &str = "user:profile";
    /// Loopback callback ports tried in order (matches the macOS app's NWListener range).
    pub const CALLBACK_PORTS: &[u16] = &[54545, 54546, 54547, 54548, 54549];
}

pub mod headers {
    /// The beta gate the private usage endpoint requires.
    pub const ANTHROPIC_BETA: &str = "oauth-2025-04-20";
    pub const USER_AGENT: &str = "monet/1.0.0";
}
