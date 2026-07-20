#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Monet desktop (Tauri) — drives the tray gauge from real Claude usage data
//! via the shared `monet-core` crate.

use std::time::Duration;

use monet_core::{Auth, UsageMetric};
use tauri::{
    image::Image,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle,
};

mod gauge;

/// Tray icon render size (rendered high, the shell scales it down crisply).
const TRAY_SIZE: u32 = 128;
/// Poll interval. The usage endpoint is rate-limited per token (~5/window), so
/// keep this conservative — matches the macOS app's default.
const POLL_SECS: u64 = 60;

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let quit = MenuItem::with_id(app, "quit", "Quit Monet", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&quit])?;

            let (rgba, w, h) = gauge::render(0.0, TRAY_SIZE);
            TrayIconBuilder::with_id("monet")
                .icon(Image::new_owned(rgba, w, h))
                .title("Monet")
                .menu(&menu)
                .tooltip("Monet — loading…")
                .on_menu_event(|app, event| {
                    if event.id.as_ref() == "quit" {
                        app.exit(0);
                    }
                })
                .build(app)?;

            // Poll real usage on Tauri's async runtime. First tick is immediate,
            // then every POLL_SECS.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let auth = Auth::new();
                loop {
                    match auth.usage().await {
                        Ok(usage) => match usage.five_hour {
                            Some(m) => apply_gauge(&handle, m.utilization, label(&m)),
                            None => apply_text(&handle, "Monet — no session data"),
                        },
                        Err(e) => apply_text(&handle, &format!("Monet — {e}")),
                    }
                    tokio::time::sleep(Duration::from_secs(POLL_SECS)).await;
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Monet");
}

/// "52% 2:36" — percentage plus time-until-reset, macOS-strip style.
fn label(m: &UsageMetric) -> String {
    let pct = m.utilization;
    match m.time_until_reset() {
        Some(d) => {
            let secs = d.num_seconds().max(0);
            let (hh, mm) = (secs / 3600, (secs % 3600) / 60);
            format!("{pct:.0}% {hh}:{mm:02}")
        }
        None => format!("{pct:.0}%"),
    }
}

/// Push a real reading to the tray (gauge icon + label + tooltip). GTK/AppIndicator
/// is not thread-safe, so marshal onto the main thread.
fn apply_gauge(handle: &AppHandle, pct: f64, label: String) {
    let h = handle.clone();
    let _ = handle.run_on_main_thread(move || {
        if let Some(tray) = h.tray_by_id("monet") {
            let (rgba, w, hh) = gauge::render(pct, TRAY_SIZE);
            let _ = tray.set_icon(Some(Image::new_owned(rgba, w, hh)));
            let _ = tray.set_title(Some(&label));
            let _ = tray.set_tooltip(Some(&format!("Monet — {label}")));
        }
    });
}

/// Surface a loading/error message on the tray tooltip without a numeric gauge.
fn apply_text(handle: &AppHandle, text: &str) {
    let h = handle.clone();
    let text = text.to_string();
    let _ = handle.run_on_main_thread(move || {
        if let Some(tray) = h.tray_by_id("monet") {
            let _ = tray.set_title(Some("—"));
            let _ = tray.set_tooltip(Some(&text));
        }
    });
}
