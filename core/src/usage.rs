//! Usage API client. Ports `Monet/Services/UsageAPIService.swift`, including the
//! brittle-by-necessity 403 body string-matching used to disambiguate the
//! private endpoint's error cases.

use crate::config;
use crate::models::UsageResponse;

/// Errors from the usage endpoint, mirroring the Swift `UsageAPIError` cases.
#[derive(Debug, thiserror::Error)]
pub enum UsageError {
    #[error("authentication token is invalid or expired")]
    InvalidToken,
    #[error("Claude Pro or Max subscription required to view usage data")]
    NoSubscription,
    #[error("Claude Code credentials cannot be used with third-party apps; sign in with OAuth instead")]
    ClaudeCodeCredentialsRestricted,
    #[error("insufficient scope: {0}")]
    InsufficientScope(String),
    #[error("rate limited")]
    RateLimited { retry_after: Option<u64> },
    #[error("server error {status}: {body}")]
    Server { status: u16, body: String },
    #[error("network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("failed to decode response: {0}")]
    Decode(String),
}

impl UsageError {
    /// Whether an auto-retry could plausibly succeed (drives the ViewModel's
    /// quiet-retry behaviour). Matches `UsageAPIError.isRecoverable`.
    pub fn is_recoverable(&self) -> bool {
        matches!(
            self,
            UsageError::Network(_) | UsageError::RateLimited { .. } | UsageError::Server { .. }
        )
    }

    /// True only for the Claude-Code-restricted case (prompts the user to switch
    /// to Monet's own OAuth). Matches `UsageAPIError.isClaudeCodeRestricted`.
    pub fn is_claude_code_restricted(&self) -> bool {
        matches!(self, UsageError::ClaudeCodeCredentialsRestricted)
    }
}

/// `GET` the usage endpoint with the given bearer token.
///
/// Pass a shared `reqwest::Client` so connection pooling is reused across polls.
pub async fn fetch_usage(
    client: &reqwest::Client,
    token: &str,
) -> Result<UsageResponse, UsageError> {
    let resp = client
        .get(config::api::USAGE_ENDPOINT)
        .bearer_auth(token)
        .header("anthropic-beta", config::headers::ANTHROPIC_BETA)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::USER_AGENT, config::headers::USER_AGENT)
        .send()
        .await?;

    let status = resp.status().as_u16();
    match status {
        200 => {
            let text = resp.text().await?;
            serde_json::from_str::<UsageResponse>(&text).map_err(|e| UsageError::Decode(e.to_string()))
        }
        401 => Err(UsageError::InvalidToken),
        403 => Err(classify_403(&resp.text().await.unwrap_or_default())),
        429 => {
            let retry_after = resp
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok());
            Err(UsageError::RateLimited { retry_after })
        }
        s => Err(UsageError::Server {
            status: s,
            body: resp.text().await.unwrap_or_default(),
        }),
    }
}

/// Disambiguate a 403 by string-matching the body — brittle by necessity, since
/// the endpoint is private/undocumented. Kept byte-compatible with the Swift.
fn classify_403(body: &str) -> UsageError {
    if body.contains("only authorized for use with Claude Code")
        || body.contains("cannot be used for other API requests")
    {
        UsageError::ClaudeCodeCredentialsRestricted
    } else if body.contains("scope") || body.contains("insufficient") {
        UsageError::InsufficientScope(body.to_string())
    } else if body.contains("permission_error")
        || body.contains("subscription")
        || body.contains("not authorized")
        || body.contains("upgrade")
    {
        UsageError::NoSubscription
    } else {
        UsageError::Server {
            status: 403,
            body: body.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_403_bodies() {
        assert!(matches!(
            classify_403("token only authorized for use with Claude Code"),
            UsageError::ClaudeCodeCredentialsRestricted
        ));
        assert!(matches!(
            classify_403("insufficient scope: user:profile"),
            UsageError::InsufficientScope(_)
        ));
        assert!(matches!(
            classify_403("permission_error: upgrade required"),
            UsageError::NoSubscription
        ));
        assert!(matches!(
            classify_403("something else entirely"),
            UsageError::Server { status: 403, .. }
        ));
    }

    #[test]
    fn warning_and_critical_bands() {
        let m = |u| UsageMetricStub { utilization: u };
        assert!(!m(74.9).warn());
        assert!(m(75.0).warn());
        assert!(m(89.9).warn());
        assert!(!m(90.0).warn() && m(90.0).crit());
    }

    // tiny stub so the band test doesn't depend on chrono/serde
    struct UsageMetricStub {
        utilization: f64,
    }
    impl UsageMetricStub {
        fn warn(&self) -> bool {
            self.utilization >= 75.0 && self.utilization < 90.0
        }
        fn crit(&self) -> bool {
            self.utilization >= 90.0
        }
    }
}
