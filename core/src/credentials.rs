//! Credential models. Ports `Monet/Models/Credentials.swift`.
//!
//! Claude Code stores its OAuth credentials in `~/.claude/.credentials.json` on
//! every platform (macOS writes the file too, in addition to the Keychain), so a
//! single file reader works everywhere — see [`crate::auth`].

use serde::{Deserialize, Serialize};

/// The on-disk shape of `~/.claude/.credentials.json`.
#[derive(Debug, Deserialize)]
pub struct ClaudeCodeCredentialsFile {
    #[serde(rename = "claudeAiOauth")]
    pub claude_ai_oauth: Option<ClaudeAiOAuthToken>,
}

/// Claude Code's OAuth token. Field names match the JSON exactly.
#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeAiOAuthToken {
    #[serde(rename = "accessToken")]
    pub access_token: String,
    #[serde(rename = "refreshToken")]
    pub refresh_token: Option<String>,
    /// Unix timestamp in **milliseconds**.
    #[serde(rename = "expiresAt")]
    pub expires_at: Option<i64>,
    pub scopes: Option<Vec<String>>,
    #[serde(rename = "subscriptionType")]
    pub subscription_type: Option<String>,
}

impl ClaudeAiOAuthToken {
    /// Expired if within 5 minutes of expiry (matches the Swift 300s buffer).
    pub fn is_expired(&self) -> bool {
        match self.expires_at {
            Some(ms) => chrono::Utc::now().timestamp() + 300 > ms / 1000,
            None => false,
        }
    }

    /// Whether the token carries the `user:profile` scope the usage API needs.
    /// If scopes are absent we optimistically assume yes and let the API decide.
    pub fn has_profile_scope(&self) -> bool {
        match &self.scopes {
            Some(s) if !s.is_empty() => s.iter().any(|x| x == "user:profile"),
            _ => true,
        }
    }
}

/// A token Monet obtained by refreshing (cached under Monet's OWN config dir —
/// never written back over Claude Code's file). Mirrors the Swift `OAuthTokens`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedToken {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds when this token was obtained.
    pub obtained_at: i64,
    /// Lifetime in seconds (`expires_in` from the token endpoint).
    pub expires_in: i64,
}

impl CachedToken {
    /// Expired if within 5 minutes of expiry.
    pub fn is_expired(&self) -> bool {
        chrono::Utc::now().timestamp() + 300 > self.obtained_at + self.expires_in
    }
}
