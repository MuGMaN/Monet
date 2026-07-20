//! Token resolution + refresh. Ports the essential path of
//! `Monet/Services/AuthenticationService.swift`.
//!
//! **Critical invariant (same as the macOS app): never write to Claude Code's
//! `~/.claude/.credentials.json`.** Monet reads it read-only and caches any token
//! it refreshes under its OWN config dir, so it can never corrupt Claude Code's
//! login.
//!
//! Resolution order in [`Auth::get_access_token`], matching the Swift three-tier
//! fallback (tier 3 — Monet's own browser OAuth — is not ported yet):
//!   1. Monet's cached, already-refreshed Claude Code token
//!   2. Claude Code's file credentials (refreshing if expired)
//!   3. *(todo)* Monet's own OAuth tokens

use std::path::PathBuf;

use serde::Deserialize;

use crate::config;
use crate::credentials::{CachedToken, ClaudeAiOAuthToken, ClaudeCodeCredentialsFile};

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("no valid authentication token found")]
    NoValidToken,
    #[error("Claude Code credentials are missing the required user:profile scope")]
    MissingScope,
    #[error("token refresh failed: {0}")]
    RefreshFailed(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("network error: {0}")]
    Network(#[from] reqwest::Error),
}

/// Response body from the OAuth token endpoint.
#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: i64,
    #[allow(dead_code)]
    token_type: Option<String>,
}

/// Resolves a usable access token, refreshing and caching as needed.
pub struct Auth {
    client: reqwest::Client,
}

impl Default for Auth {
    fn default() -> Self {
        Self::new()
    }
}

impl Auth {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::new(),
        }
    }

    /// Convenience: resolve a token and fetch usage in one call — the single
    /// entry point a UI shell needs.
    pub async fn usage(&self) -> Result<crate::models::UsageResponse, crate::FetchError> {
        let token = self.get_access_token().await?;
        Ok(crate::usage::fetch_usage(&self.client, &token).await?)
    }

    /// Resolve a valid access token, or error if none can be obtained.
    pub async fn get_access_token(&self) -> Result<String, AuthError> {
        // 1. Monet's cache of an already-refreshed Claude Code token.
        if let Some(cached) = read_cache() {
            if !cached.is_expired() {
                return Ok(cached.access_token);
            }
        }

        // 2. Claude Code's own credentials (read-only).
        if let Some(cc) = read_claude_code() {
            if !cc.has_profile_scope() {
                return Err(AuthError::MissingScope);
            }
            if !cc.is_expired() {
                return Ok(cc.access_token);
            }
            // Expired locally — try to refresh, caching the result under Monet's
            // OWN store (never Claude Code's file).
            if let Some(refresh) = &cc.refresh_token {
                let fresh = self.refresh(refresh).await?;
                let token = fresh.access_token.clone();
                if let Err(e) = write_cache(&fresh) {
                    // Non-fatal: we still return the freshly minted token.
                    #[cfg(debug_assertions)]
                    eprintln!("[monet-core] failed to cache refreshed token: {e}");
                    let _ = e;
                }
                return Ok(token);
            }
        }

        // 3. TODO: Monet's own OAuth tokens (browser flow) — not ported yet.
        Err(AuthError::NoValidToken)
    }

    /// Exchange a refresh token for a fresh access token. Byte-compatible with
    /// Claude Code's refresh body (JSON with `scope`).
    async fn refresh(&self, refresh_token: &str) -> Result<CachedToken, AuthError> {
        let body = serde_json::json!({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": config::oauth::CLIENT_ID,
            "scope": config::oauth::SCOPES,
        });

        let resp = self
            .client
            .post(config::api::TOKEN_ENDPOINT)
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(AuthError::RefreshFailed(format!("HTTP {status}: {text}")));
        }

        let tr: TokenResponse = resp
            .json()
            .await
            .map_err(|e| AuthError::RefreshFailed(format!("decode: {e}")))?;

        Ok(CachedToken {
            access_token: tr.access_token,
            // The endpoint may or may not rotate the refresh token; keep the old
            // one if it doesn't return a new one.
            refresh_token: tr.refresh_token.or_else(|| Some(refresh_token.to_string())),
            obtained_at: chrono::Utc::now().timestamp(),
            expires_in: tr.expires_in,
        })
    }
}

// ---- file locations ----

fn claude_code_creds_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude").join(".credentials.json"))
}

/// Monet's OWN cache path (never Claude Code's file):
/// Linux `~/.config/monet/…`, macOS `~/Library/Application Support/monet/…`.
fn cache_path() -> Option<PathBuf> {
    dirs::config_dir().map(|c| c.join("monet").join("claude-code-cache.json"))
}

// ---- read/write (Claude Code file is READ-ONLY) ----

fn read_claude_code() -> Option<ClaudeAiOAuthToken> {
    let path = claude_code_creds_path()?;
    let data = std::fs::read_to_string(path).ok()?;
    let file: ClaudeCodeCredentialsFile = serde_json::from_str(&data).ok()?;
    file.claude_ai_oauth
}

fn read_cache() -> Option<CachedToken> {
    let path = cache_path()?;
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

fn write_cache(token: &CachedToken) -> Result<(), AuthError> {
    let path = cache_path().ok_or_else(|| AuthError::Io("no config dir".into()))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| AuthError::Io(e.to_string()))?;
    }
    let json = serde_json::to_vec_pretty(token).map_err(|e| AuthError::Io(e.to_string()))?;
    std::fs::write(&path, json).map_err(|e| AuthError::Io(e.to_string()))?;
    // Lock it down to 0600 — it holds a bearer token (same posture as Claude
    // Code's own 0600 credentials file).
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}
