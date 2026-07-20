#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Monet desktop (Tauri) — tray gauge + drop-down usage panel, driven by real
//! Claude usage data via the shared `monet-core` crate.

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use monet_core::{Auth, UsageMetric};
use serde::Serialize;
use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, LogicalPosition, Manager, WindowEvent,
};

mod gauge;

const TRAY_SIZE: u32 = 128;
const POLL_SECS: u64 = 60;
const PANEL_WIDTH: f64 = 360.0;

/// A single metric as the panel consumes it (raw; formatting happens in JS).
#[derive(Serialize, Clone, Default)]
struct Metric {
    utilization: f64,
    resets_at: Option<String>,
}

impl From<&UsageMetric> for Metric {
    fn from(m: &UsageMetric) -> Self {
        Metric {
            utilization: m.utilization,
            resets_at: m.resets_at.clone(),
        }
    }
}

/// The full state the panel renders. Serialized to the frontend via a command
/// (on open) and a `state-updated` event (on every poll).
#[derive(Serialize, Clone, Default)]
struct PanelState {
    loading: bool,
    error: Option<String>,
    authenticated: bool,
    /// Epoch millis of the last successful update (formatted in JS).
    last_updated_ms: Option<u64>,
    session: Option<Metric>,
    weekly: Option<Metric>,
    opus: Option<Metric>,
    sonnet: Option<Metric>,
}

struct AppState {
    panel: Mutex<PanelState>,
    auth: Arc<Auth>,
    notify: Arc<tokio::sync::Notify>,
}

// ---- IPC commands (called from the panel's JS) ----

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> PanelState {
    state.panel.lock().unwrap().clone()
}

#[tauri::command]
fn refresh_now(state: tauri::State<AppState>) {
    state.notify.notify_one();
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

fn main() {
    let auth = Arc::new(Auth::new());
    let notify = Arc::new(tokio::sync::Notify::new());
    let notify_loop = notify.clone();

    tauri::Builder::default()
        .manage(AppState {
            panel: Mutex::new(PanelState::default()),
            auth,
            notify,
        })
        .invoke_handler(tauri::generate_handler![get_state, refresh_now, quit_app])
        // Dismiss the panel when it loses focus (popover behavior).
        .on_window_event(|window, event| {
            // Test hook: keep the panel pinned open so it can be screenshotted.
            if std::env::var_os("MONET_SHOW_ON_START").is_some() {
                return;
            }
            if let WindowEvent::Focused(false) = event {
                if window.label() == "main" {
                    let _ = window.hide();
                }
            }
        })
        .setup(move |app| {
            // On Linux/GNOME the AppIndicator REQUIRES a menu — both to render the
            // icon + label at all, and because the desktop shows the menu on click
            // (Tauri never receives Linux tray-click events). macOS/Windows also get
            // direct click-to-toggle via on_tray_icon_event below.
            let open = MenuItem::with_id(app, "show", "Open Monet", true, None::<&str>)?;
            let sep = PredefinedMenuItem::separator(app)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Monet", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &sep, &quit])?;

            let (rgba, w, h) = gauge::render(0.0, TRAY_SIZE);
            TrayIconBuilder::with_id("monet")
                .icon(Image::new_owned(rgba, w, h))
                .title("Monet")
                .tooltip("Monet — loading…")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_panel(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        toggle_panel(tray.app_handle());
                    }
                })
                .build(app)?;

            // Poll loop: immediate first tick, then every POLL_SECS or on demand.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    poll_and_update(&handle).await;
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(POLL_SECS)) => {}
                        _ = notify_loop.notified() => {}
                    }
                }
            });

            // Test hook: open the panel on launch for screenshotting.
            if std::env::var_os("MONET_SHOW_ON_START").is_some() {
                show_panel(app.handle());
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Monet");
}

/// One poll: fetch usage, update shared state + tray, and notify the panel.
async fn poll_and_update(app: &AppHandle) {
    {
        let st = app.state::<AppState>();
        st.panel.lock().unwrap().loading = true;
    }
    emit_state(app);

    let auth = app.state::<AppState>().auth.clone();
    let result = auth.usage().await;

    let mut tray: Option<(f64, String)> = None;
    {
        let st = app.state::<AppState>();
        let mut p = st.panel.lock().unwrap();
        p.loading = false;
        match result {
            Ok(u) => {
                if let Some(m) = &u.five_hour {
                    tray = Some((m.utilization, tray_label(m)));
                }
                p.error = None;
                p.authenticated = true;
                p.last_updated_ms = Some(now_ms());
                p.session = u.five_hour.as_ref().map(Metric::from);
                p.weekly = u.seven_day.as_ref().map(Metric::from);
                p.opus = u.seven_day_opus.as_ref().map(Metric::from);
                p.sonnet = u.seven_day_sonnet.as_ref().map(Metric::from);
            }
            Err(e) => {
                let msg = e.to_string();
                if msg.to_lowercase().contains("no valid") {
                    p.authenticated = false;
                }
                p.error = Some(msg);
            }
        }
    }

    match tray {
        Some((pct, label)) => update_tray(app, pct, label),
        None => set_tray_text(app, "Monet — no data"),
    }
    emit_state(app);
}

/// "48% 2:36" from a metric.
fn tray_label(m: &UsageMetric) -> String {
    let pct = m.utilization;
    match m.time_until_reset() {
        Some(d) => {
            let s = d.num_seconds().max(0);
            format!("{pct:.0}% {}:{:02}", s / 3600, (s % 3600) / 60)
        }
        None => format!("{pct:.0}%"),
    }
}

fn update_tray(app: &AppHandle, pct: f64, label: String) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(tray) = app.tray_by_id("monet") {
            let (rgba, w, h) = gauge::render(pct, TRAY_SIZE);
            let _ = tray.set_icon(Some(Image::new_owned(rgba, w, h)));
            let _ = tray.set_title(Some(&label));
            let _ = tray.set_tooltip(Some(&format!("Monet — {label}")));
        }
    });
}

fn set_tray_text(app: &AppHandle, text: &str) {
    let app = app.clone();
    let text = text.to_string();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(tray) = app.tray_by_id("monet") {
            let _ = tray.set_tooltip(Some(&text));
        }
    });
}

fn emit_state(app: &AppHandle) {
    let payload = app.state::<AppState>().panel.lock().unwrap().clone();
    let _ = app.emit("state-updated", payload);
}

/// Show the panel window, positioned top-right near the tray, and refresh it.
/// Closing is handled by the panel itself (× / Escape / click-away).
fn show_panel(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        if let Ok(Some(monitor)) = win.primary_monitor() {
            let scale = monitor.scale_factor();
            let logical_w = monitor.size().width as f64 / scale;
            let x = (logical_w - PANEL_WIDTH - 8.0).max(8.0);
            let _ = win.set_position(LogicalPosition::new(x, 36.0));
        }
        let _ = win.show();
        let _ = win.set_focus();
        app.state::<AppState>().notify.notify_one();
    }
}

/// Toggle the panel (used by left-click on macOS/Windows, where the tray icon
/// sends click events; on Linux the "Open Monet" menu item calls `show_panel`).
fn toggle_panel(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        if win.is_visible().unwrap_or(false) {
            let _ = win.hide();
            return;
        }
    }
    show_panel(app);
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
