//! API data models for the usage endpoint. Ports the DTOs in
//! `Monet/Models/UsageData.swift`.

use serde::Deserialize;

/// Top-level response from `GET /api/oauth/usage`.
///
/// Unknown fields (e.g. the mystery `iguana_necktie` seen in the Swift model)
/// are ignored by serde, so we simply omit them.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct UsageResponse {
    pub five_hour: Option<UsageMetric>,
    pub seven_day: Option<UsageMetric>,
    pub seven_day_opus: Option<UsageMetric>,
    pub seven_day_sonnet: Option<UsageMetric>,
    pub seven_day_oauth_apps: Option<UsageMetric>,
}

/// A single usage metric: a utilization percentage plus an optional reset time.
#[derive(Debug, Clone, Deserialize)]
pub struct UsageMetric {
    /// Usage percentage in the range 0..=100.
    pub utilization: f64,
    /// ISO-8601 timestamp when this window resets, if known.
    pub resets_at: Option<String>,
}

impl UsageMetric {
    /// Warning band: 75% up to (but not including) 90%. Matches `UsageMetric.isWarning`.
    pub fn is_warning(&self) -> bool {
        self.utilization >= 75.0 && self.utilization < 90.0
    }

    /// Critical band: 90% and above. Matches `UsageMetric.isCritical`.
    pub fn is_critical(&self) -> bool {
        self.utilization >= 90.0
    }

    /// Parse `resets_at` into a UTC instant, if present and valid.
    pub fn reset_date(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        self.resets_at
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.with_timezone(&chrono::Utc))
    }

    /// Time remaining until reset, or `None` if unknown or already elapsed.
    pub fn time_until_reset(&self) -> Option<chrono::Duration> {
        self.reset_date()
            .map(|d| d - chrono::Utc::now())
            .filter(|d| d.num_seconds() > 0)
    }
}
