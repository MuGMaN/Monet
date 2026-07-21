//! Monet's own browser OAuth (tier-3 sign-in), for users who don't have Claude
//! Code installed. Ports the flow of `AuthenticationService.startOAuthFlow`:
//! it **impersonates Claude Code** — same public client id, `user:profile`
//! scope, PKCE (S256), and a **loopback HTTP callback server** on ports
//! 54545–54549 (not a custom URL scheme). The token-exchange body is
//! byte-compatible with Claude Code's (grant_type/code/redirect_uri/client_id/
//! code_verifier/state).

use std::time::Duration;

use base64::Engine;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::config;

/// How long to wait for the user to finish authorizing in the browser.
pub const CALLBACK_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, thiserror::Error)]
pub enum OAuthError {
    #[error("could not bind any OAuth callback port (54545–54549) — another app may be using them")]
    NoFreePort,
    #[error("authorization timed out — the browser may not have opened")]
    TimedOut,
    #[error("security state mismatch in OAuth callback")]
    StateMismatch,
    #[error("no authorization code in callback{0}")]
    NoCode(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("invalid authorization URL: {0}")]
    Url(String),
}

/// A started login: the authorize URL to open, plus the state needed to finish.
pub struct PendingLogin {
    /// The URL to open in the user's browser.
    pub authorize_url: String,
    code_verifier: String,
    state: String,
    redirect_uri: String,
    listener: TcpListener,
}

/// The result of a successful callback — everything the token exchange needs.
pub struct AuthCode {
    pub code: String,
    pub code_verifier: String,
    pub redirect_uri: String,
    pub state: String,
}

/// Generate PKCE params, bind the loopback callback server, and build the
/// authorize URL. Call [`PendingLogin::wait_for_code`] after opening the URL.
pub async fn begin() -> Result<PendingLogin, OAuthError> {
    let code_verifier = random_b64url(32);
    let code_challenge = challenge_of(&code_verifier);
    let state = random_b64url(32);

    // Bind the callback server first, so it's ready before the browser opens.
    let mut bound: Option<(TcpListener, u16)> = None;
    for &port in config::oauth::CALLBACK_PORTS {
        if let Ok(l) = TcpListener::bind(("127.0.0.1", port)).await {
            bound = Some((l, port));
            break;
        }
    }
    let (listener, port) = bound.ok_or(OAuthError::NoFreePort)?;
    let redirect_uri = format!("http://localhost:{port}/callback");

    // Byte-for-byte the same query the macOS app sends (note `code=true`).
    let authorize_url = reqwest::Url::parse_with_params(
        config::api::AUTHORIZATION_ENDPOINT,
        &[
            ("code", "true"),
            ("client_id", config::oauth::CLIENT_ID),
            ("response_type", "code"),
            ("redirect_uri", redirect_uri.as_str()),
            ("scope", config::oauth::SCOPES),
            ("code_challenge", code_challenge.as_str()),
            ("code_challenge_method", "S256"),
            ("state", state.as_str()),
        ],
    )
    .map_err(|e| OAuthError::Url(e.to_string()))?
    .to_string();

    Ok(PendingLogin {
        authorize_url,
        code_verifier,
        state,
        redirect_uri,
        listener,
    })
}

impl PendingLogin {
    /// Accept the browser's redirect, reply with a success page, and return the
    /// authorization code (after verifying the CSRF `state`).
    pub async fn wait_for_code(self, timeout: Duration) -> Result<AuthCode, OAuthError> {
        let path = tokio::time::timeout(timeout, accept_callback(&self.listener))
            .await
            .map_err(|_| OAuthError::TimedOut)??;

        // Parse ?code=…&state=… by resolving the request-target against a dummy base.
        let url = reqwest::Url::parse(&format!("http://localhost{path}"))
            .map_err(|e| OAuthError::Url(e.to_string()))?;
        let mut code = None;
        let mut got_state = None;
        let mut err = None;
        for (k, v) in url.query_pairs() {
            match k.as_ref() {
                "code" => code = Some(v.into_owned()),
                "state" => got_state = Some(v.into_owned()),
                "error" => err = Some(v.into_owned()),
                _ => {}
            }
        }

        if got_state.as_deref() != Some(self.state.as_str()) {
            return Err(OAuthError::StateMismatch);
        }
        let code = code.ok_or_else(|| {
            OAuthError::NoCode(err.map(|e| format!(" (server said: {e})")).unwrap_or_default())
        })?;

        Ok(AuthCode {
            code,
            code_verifier: self.code_verifier,
            redirect_uri: self.redirect_uri,
            state: self.state,
        })
    }
}

/// Loop until a request hits `/callback`; answer other paths (e.g. favicon) 404.
async fn accept_callback(listener: &TcpListener) -> Result<String, OAuthError> {
    loop {
        let (mut stream, _) = listener.accept().await.map_err(|e| OAuthError::Io(e.to_string()))?;
        let mut buf = [0u8; 8192];
        let n = match stream.read(&mut buf).await {
            Ok(0) | Err(_) => continue,
            Ok(n) => n,
        };
        let req = String::from_utf8_lossy(&buf[..n]);
        // Request line: "GET /callback?… HTTP/1.1"
        let target = req
            .lines()
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .unwrap_or("");

        if !target.starts_with("/callback") {
            let _ = stream
                .write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
                .await;
            continue;
        }

        let _ = stream.write_all(SUCCESS_PAGE).await;
        let _ = stream.flush().await;
        return Ok(target.to_string());
    }
}

const SUCCESS_PAGE: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\
<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Monet - Authorization Complete</title></head>\
<body style=\"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Ubuntu,sans-serif;display:flex;\
justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff;\">\
<div style=\"text-align:center;\"><h1>Authorization Successful</h1>\
<p>You can close this window and return to Monet.</p></div></body></html>";

// ---- PKCE helpers ----

/// `n` random bytes, base64url-encoded without padding (RFC 7636 code verifier / state).
fn random_b64url(n: usize) -> String {
    let mut bytes = vec![0u8; n];
    // OS CSPRNG; on the astronomically-unlikely failure, fall back to a
    // time-seeded value so login degrades rather than panicking.
    if getrandom::getrandom(&mut bytes).is_err() {
        let t = chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0).to_le_bytes();
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = t[i % t.len()] ^ (i as u8);
        }
    }
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// S256 challenge = base64url(SHA256(verifier)).
fn challenge_of(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

/// Open a URL in the user's default browser (best-effort, per-OS).
pub fn open_in_browser(url: &str) {
    #[cfg(target_os = "linux")]
    let _ = std::process::Command::new("xdg-open").arg(url).spawn();
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(url).spawn();
    #[cfg(target_os = "windows")]
    open_in_browser_windows(url);
}

/// Windows: open a URL via `ShellExecuteW`, NOT `cmd /C start <url>`.
///
/// `cmd.exe` treats `&` as a command separator, and every query parameter in the
/// OAuth authorize URL is joined by `&` — so `cmd /C start "" ".../authorize?code=true&client_id=…"`
/// truncates the URL at the first `&`. The browser then receives only
/// `?code=true` and Claude rejects it with "Invalid OAuth Request: Missing
/// client_id parameter". `ShellExecuteW` hands the URL to the shell verbatim,
/// with no metacharacter parsing.
#[cfg(target_os = "windows")]
fn open_in_browser_windows(url: &str) {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

    let wide = |s: &str| -> Vec<u16> {
        std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
    };
    let verb = wide("open");
    let file = wide(url);
    unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            SW_SHOWNORMAL,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc7636_vector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(challenge_of(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[tokio::test]
    async fn authorize_url_and_callback_roundtrip() {
        let pending = begin().await.expect("begin");
        let url = reqwest::Url::parse(&pending.authorize_url).unwrap();
        let q: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();

        // Impersonation contract must be exact.
        assert_eq!(url.as_str().split('?').next().unwrap(), config::api::AUTHORIZATION_ENDPOINT);
        assert_eq!(q["client_id"], config::oauth::CLIENT_ID);
        assert_eq!(q["scope"], config::oauth::SCOPES);
        assert_eq!(q["response_type"], "code");
        assert_eq!(q["code"], "true");
        assert_eq!(q["code_challenge_method"], "S256");
        assert!(!q["code_challenge"].is_empty());

        let state = q["state"].clone();
        let port: u16 = q["redirect_uri"]
            .trim_start_matches("http://localhost:")
            .trim_end_matches("/callback")
            .parse()
            .unwrap();

        // Simulate the browser hitting the loopback callback.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
            let req = format!("GET /callback?code=testcode&state={state} HTTP/1.1\r\nHost: localhost\r\n\r\n");
            s.write_all(req.as_bytes()).await.unwrap();
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf).await; // let the server finish sending the page
        });

        let got = pending.wait_for_code(Duration::from_secs(5)).await.expect("callback");
        assert_eq!(got.code, "testcode");
    }

    #[tokio::test]
    async fn callback_rejects_state_mismatch() {
        let pending = begin().await.expect("begin");
        let url = reqwest::Url::parse(&pending.authorize_url).unwrap();
        let port: u16 = url
            .query_pairs()
            .find(|(k, _)| k == "redirect_uri")
            .unwrap()
            .1
            .trim_start_matches("http://localhost:")
            .trim_end_matches("/callback")
            .parse()
            .unwrap();

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
            let req = "GET /callback?code=x&state=WRONG HTTP/1.1\r\nHost: localhost\r\n\r\n";
            s.write_all(req.as_bytes()).await.unwrap();
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf).await;
        });

        let err = pending.wait_for_code(Duration::from_secs(5)).await;
        assert!(matches!(err, Err(OAuthError::StateMismatch)));
    }
}
