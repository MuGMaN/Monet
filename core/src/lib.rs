//! monet-core — shared, platform-independent logic for Monet (the Claude usage monitor).
//!
//! This crate is the single source of truth for everything that is not UI or
//! OS integration: the API data models, the usage-endpoint client, and (added
//! incrementally) the OAuth/PKCE flow, token refresh, secure token cache, and
//! Claude Code credential discovery.
//!
//! Platform shells build on top of it:
//!   - `macos/`   — the existing SwiftUI app (may adopt this core via FFI later)
//!   - `desktop/` — the Tauri app (Windows + Linux, and a macOS build option)
//!
//! Ports of the Swift originals are noted per-module.

pub mod auth;
pub mod config;
pub mod credentials;
pub mod models;
pub mod usage;

pub use auth::{Auth, AuthError};
pub use credentials::{CachedToken, ClaudeAiOAuthToken};
pub use models::{UsageMetric, UsageResponse};
pub use usage::{fetch_usage, UsageError};

/// Combined error for the one-shot [`Auth::usage`] convenience.
#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error(transparent)]
    Auth(#[from] AuthError),
    #[error(transparent)]
    Usage(#[from] UsageError),
}
