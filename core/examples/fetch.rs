//! Headless end-to-end check of the real data path:
//!   read Claude Code creds -> (refresh if needed) -> GET the usage endpoint.
//!
//! Prints the real utilization numbers and reset times. **Never prints the
//! access token.** Run from `core/`:  `cargo run --example fetch`

use monet_core::{fetch_usage, Auth, UsageMetric};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let auth = Auth::new();

    let token = match auth.get_access_token().await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("auth failed: {e}");
            std::process::exit(1);
        }
    };
    // Confirm we got *a* token without ever revealing it.
    println!("resolved an access token (len {}, not shown)\n", token.len());

    let client = reqwest::Client::new();
    match fetch_usage(&client, &token).await {
        Ok(u) => {
            println!("REAL usage from api.anthropic.com/api/oauth/usage:");
            show("five_hour (session)", &u.five_hour);
            show("seven_day (weekly)", &u.seven_day);
            show("seven_day_opus", &u.seven_day_opus);
            show("seven_day_sonnet", &u.seven_day_sonnet);
        }
        Err(e) => {
            eprintln!("usage fetch failed: {e}");
            std::process::exit(1);
        }
    }
}

fn show(name: &str, m: &Option<UsageMetric>) {
    match m {
        Some(x) => {
            let reset = x.resets_at.as_deref().unwrap_or("-");
            println!("  {name:22} {:>5.1}%   resets_at={reset}", x.utilization);
        }
        None => println!("  {name:22} (none)"),
    }
}
