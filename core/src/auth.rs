//! Token resolution + refresh. Ports the essential path of
//! `Monet/Services/AuthenticationService.swift`.
//!
//! **Critical invariant (same as the macOS app): never write to Claude Code's
//! `~/.claude/.credentials.json`.** Monet reads it read-only and caches any token
//! it refreshes under its OWN config dir, so it can never corrupt Claude Code's
//! login.
//!
//! Resolution order in [`Auth::get_access_token`], matching the Swift three-tier
//! fallback:
//!   1. Monet's cached, already-refreshed Claude Code token
//!   2. Claude Code's file credentials (refreshing if expired)
//!   3. Monet's own OAuth tokens (browser sign-in — see [`crate::oauth`])

use std::path::PathBuf;

use serde::Deserialize;

use crate::config;
use crate::credentials::{CachedToken, ClaudeAiOAuthToken, ClaudeCodeCredentialsFile};
use crate::oauth::{self, OAuthError};

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("no valid authentication token found")]
    NoValidToken,
    #[error("Claude Code credentials are missing the required user:profile scope")]
    MissingScope,
    #[error("token refresh failed: {0}")]
    RefreshFailed(String),
    #[error("token exchange failed: {0}")]
    ExchangeFailed(String),
    #[error(transparent)]
    OAuth(#[from] OAuthError),
    #[error("io error: {0}")]
    Io(String),
    #[error("network error: {0}")]
    Network(#[from] reqwest::Error),
}

/// Which tier currently backs the resolved token — used only for UI labelling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthSource {
    /// Claude Code's credentials (read-only) or Monet's refreshed cache of them.
    ClaudeCode,
    /// Monet's own browser OAuth tokens.
    MonetOAuth,
}

impl AuthSource {
    /// Stable string for IPC/UI (`"claude_code"` | `"monet"`).
    pub fn as_str(self) -> &'static str {
        match self {
            AuthSource::ClaudeCode => "claude_code",
            AuthSource::MonetOAuth => "monet",
        }
    }
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

        // 3. Monet's own OAuth tokens (browser sign-in).
        if let Some(tok) = read_oauth() {
            if !tok.is_expired() {
                return Ok(tok.access_token);
            }
            if let Some(refresh) = &tok.refresh_token {
                let fresh = self.refresh(refresh).await?;
                let token = fresh.access_token.clone();
                let _ = write_oauth(&fresh);
                return Ok(token);
            }
        }

        Err(AuthError::NoValidToken)
    }

    /// Run Monet's own browser OAuth flow end-to-end: open the browser, catch the
    /// loopback callback, exchange the code, and persist the tokens under Monet's
    /// own store. Used when there are no Claude Code credentials.
    pub async fn login(&self) -> Result<(), AuthError> {
        let pending = oauth::begin().await?;
        oauth::open_in_browser(&pending.authorize_url);
        let code = pending.wait_for_code(oauth::CALLBACK_TIMEOUT).await?;
        let tokens = self.exchange_code(&code).await?;
        write_oauth(&tokens)?;
        Ok(())
    }

    /// Sign out of Monet's own OAuth (and drop the refreshed Claude Code cache).
    /// Never touches Claude Code's own credentials file.
    pub fn sign_out(&self) {
        if let Some(p) = oauth_path() {
            let _ = std::fs::remove_file(p);
        }
        if let Some(p) = cache_path() {
            let _ = std::fs::remove_file(p);
        }
    }

    /// Whether Monet's own OAuth token store already exists.
    pub fn has_own_oauth(&self) -> bool {
        read_oauth().is_some()
    }

    /// Seed Monet's own OAuth store from an external source (e.g. migrating the
    /// native macOS app's Keychain token). No-op if a token already exists, so it
    /// never clobbers a fresh sign-in. `obtained_at` is Unix seconds.
    pub fn seed_own_oauth(
        &self,
        access_token: String,
        refresh_token: Option<String>,
        obtained_at: i64,
        expires_in: i64,
    ) {
        if read_oauth().is_some() {
            return;
        }
        let _ = write_oauth(&CachedToken {
            access_token,
            refresh_token,
            obtained_at,
            expires_in,
        });
    }

    /// Which tier would back the next token, computed from local files only (no
    /// network). Mirrors the [`Self::get_access_token`] order; for UI labelling.
    pub fn current_source(&self) -> Option<AuthSource> {
        if read_cache().map(|c| !c.is_expired()).unwrap_or(false) {
            return Some(AuthSource::ClaudeCode);
        }
        if read_claude_code()
            .map(|c| c.has_profile_scope() && !c.is_expired())
            .unwrap_or(false)
        {
            return Some(AuthSource::ClaudeCode);
        }
        if read_oauth().is_some() {
            return Some(AuthSource::MonetOAuth);
        }
        None
    }

    /// Exchange an authorization code for tokens. Byte-compatible with Claude
    /// Code's exchange body (JSON: grant_type/code/redirect_uri/client_id/
    /// code_verifier/state).
    async fn exchange_code(&self, code: &oauth::AuthCode) -> Result<CachedToken, AuthError> {
        let body = serde_json::json!({
            "grant_type": "authorization_code",
            "code": code.code,
            "redirect_uri": code.redirect_uri,
            "client_id": config::oauth::CLIENT_ID,
            "code_verifier": code.code_verifier,
            "state": code.state,
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
            return Err(AuthError::ExchangeFailed(format!("HTTP {status}: {text}")));
        }

        let tr: TokenResponse = resp
            .json()
            .await
            .map_err(|e| AuthError::ExchangeFailed(format!("decode: {e}")))?;

        Ok(CachedToken {
            access_token: tr.access_token,
            refresh_token: tr.refresh_token,
            obtained_at: chrono::Utc::now().timestamp(),
            expires_in: tr.expires_in,
        })
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

/// Where Monet stores tokens minted by its OWN browser OAuth (tier 3). Distinct
/// from the Claude Code cache so signing out of one doesn't disturb the other.
fn oauth_path() -> Option<PathBuf> {
    dirs::config_dir().map(|c| c.join("monet").join("oauth.json"))
}

// ---- read/write (Claude Code file is READ-ONLY) ----

fn read_claude_code() -> Option<ClaudeAiOAuthToken> {
    let path = claude_code_creds_path()?;
    let data = std::fs::read_to_string(path).ok()?;
    let file: ClaudeCodeCredentialsFile = serde_json::from_str(&data).ok()?;
    file.claude_ai_oauth
}

fn read_cache() -> Option<CachedToken> {
    read_token(cache_path()?)
}

fn write_cache(token: &CachedToken) -> Result<(), AuthError> {
    write_token(cache_path().ok_or_else(|| AuthError::Io("no config dir".into()))?, token)
}

fn read_oauth() -> Option<CachedToken> {
    read_token(oauth_path()?)
}

fn write_oauth(token: &CachedToken) -> Result<(), AuthError> {
    write_token(oauth_path().ok_or_else(|| AuthError::Io("no config dir".into()))?, token)
}

fn read_token(path: PathBuf) -> Option<CachedToken> {
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

/// Write a token as pretty JSON, then lock it to 0600 — it holds a bearer token
/// (same posture as Claude Code's own 0600 credentials file).
fn write_token(path: PathBuf, token: &CachedToken) -> Result<(), AuthError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| AuthError::Io(e.to_string()))?;
    }
    let json = serde_json::to_vec_pretty(token).map_err(|e| AuthError::Io(e.to_string()))?;
    std::fs::write(&path, json).map_err(|e| AuthError::Io(e.to_string()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}
