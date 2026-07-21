#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Monet desktop (Tauri) — tray gauge + drop-down usage panel + settings,
//! driven by real Claude usage data via the shared `monet-core` crate.

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use monet_core::{Auth, UsageMetric};
use serde::{Deserialize, Serialize};
use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, LogicalPosition, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_updater::UpdaterExt;

mod gauge;

/// The GitLab releases page, opened when a `.deb`/system install can't self-update.
const RELEASES_URL: &str = "https://gitlab.ericandjoe.work/eric/Monet/-/releases";

const TRAY_SIZE: u32 = 128;
const PANEL_WIDTH: f64 = 360.0;

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

#[derive(Serialize, Clone, Default)]
struct PanelState {
    loading: bool,
    error: Option<String>,
    authenticated: bool,
    /// Which tier backs auth right now: "claude_code" | "monet" | null.
    auth_source: Option<String>,
    last_updated_ms: Option<u64>,
    session: Option<Metric>,
    weekly: Option<Metric>,
    opus: Option<Metric>,
    sonnet: Option<Metric>,
}

/// User preferences, persisted to `<config>/monet/settings.json`.
#[derive(Serialize, Deserialize, Clone)]
struct Settings {
    /// Tray label density: "minimal" (gauge only) | "normal" (% + h:mm) | "verbose" (% + h:mm:ss).
    display_mode: String,
    /// Poll interval, seconds.
    refresh_secs: u64,
    launch_at_login: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Settings {
            display_mode: "normal".into(),
            refresh_secs: 60,
            launch_at_login: false,
        }
    }
}

struct AppState {
    panel: Mutex<PanelState>,
    settings: Mutex<Settings>,
    auth: Arc<Auth>,
    notify: Arc<tokio::sync::Notify>,
}

// ---- IPC commands ----

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

#[tauri::command]
fn get_settings(state: tauri::State<AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
fn set_settings(app: AppHandle, settings: Settings) {
    {
        let st = app.state::<AppState>();
        *st.settings.lock().unwrap() = settings.clone();
    }
    save_settings(&settings);
    apply_autostart(&app, settings.launch_at_login);
    rerender_tray(&app); // display mode may have changed
    app.state::<AppState>().notify.notify_one(); // refresh interval may have changed
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let _ = build_settings_window(&app);
}

// ---- auto-update ----

#[derive(Serialize, Clone, Default)]
struct UpdateInfo {
    available: bool,
    version: Option<String>,
    notes: Option<String>,
    /// True only when the running install can replace itself in place (AppImage).
    /// A `.deb`/system install is owned by the package manager, so we notify instead.
    can_auto_install: bool,
}

/// AppImage sets `$APPIMAGE` to the mounted image path; its absence means we're a
/// `.deb`/system install (or a raw dev binary) that must not self-swap.
fn is_appimage() -> bool {
    std::env::var_os("APPIMAGE").is_some()
}

#[tauri::command]
async fn check_update(app: AppHandle) -> Result<UpdateInfo, String> {
    let updater = app.updater().map_err(|e| e.to_string())?;
    match updater.check().await {
        Ok(Some(update)) => Ok(UpdateInfo {
            available: true,
            version: Some(update.version.clone()),
            notes: update.body.clone(),
            can_auto_install: is_appimage(),
        }),
        Ok(None) => Ok(UpdateInfo {
            can_auto_install: is_appimage(),
            ..Default::default()
        }),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
async fn install_update(app: AppHandle) -> Result<(), String> {
    if !is_appimage() {
        return Err("not-appimage".into());
    }
    let updater = app.updater().map_err(|e| e.to_string())?;
    let update = updater
        .check()
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "no update available".to_string())?;
    update
        .download_and_install(|_downloaded, _total| {}, || {})
        .await
        .map_err(|e| e.to_string())?;
    app.restart();
}

// ---- sign-in (tier-3 browser OAuth) ----

/// Run Monet's own browser OAuth flow (for users without Claude Code). Opens the
/// browser, catches the loopback callback, stores tokens, then refreshes the UI.
#[tauri::command]
async fn start_login(app: AppHandle) -> Result<(), String> {
    let auth = { app.state::<AppState>().auth.clone() };
    auth.login().await.map_err(|e| e.to_string())?;
    app.state::<AppState>().notify.notify_one();
    Ok(())
}

/// Sign out of Monet's own OAuth (leaves Claude Code's credentials untouched).
#[tauri::command]
fn sign_out(app: AppHandle) {
    app.state::<AppState>().auth.sign_out();
    app.state::<AppState>().notify.notify_one();
}

/// Open the GitLab releases page (for `.deb`/system installs that can't self-update).
#[tauri::command]
fn open_release_page() {
    #[cfg(target_os = "linux")]
    let _ = std::process::Command::new("xdg-open").arg(RELEASES_URL).spawn();
    #[cfg(target_os = "windows")]
    let _ = std::process::Command::new("cmd")
        .args(["/C", "start", "", RELEASES_URL])
        .spawn();
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(RELEASES_URL).spawn();
}

fn build_settings_window(app: &AppHandle) -> tauri::Result<()> {
    let mut builder = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("Monet Settings")
        .inner_size(420.0, 560.0)
        .resizable(false)
        .center();
    // Give the window the Monet icon so it shows in the taskbar/dock (rather than
    // the generic gear the dev binary gets without a matching .desktop file).
    if let Ok(icon) = tauri::image::Image::from_bytes(include_bytes!("../icons/128x128.png")) {
        builder = builder.icon(icon)?;
    }
    builder.build()?;
    Ok(())
}

fn main() {
    let auth = Arc::new(Auth::new());
    let notify = Arc::new(tokio::sync::Notify::new());
    let notify_loop = notify.clone();
    let settings = load_settings();

    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState {
            panel: Mutex::new(PanelState::default()),
            settings: Mutex::new(settings),
            auth,
            notify,
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            refresh_now,
            quit_app,
            get_settings,
            set_settings,
            open_settings,
            check_update,
            install_update,
            open_release_page,
            start_login,
            sign_out
        ])
        .on_window_event(|window, event| {
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
            let open = MenuItem::with_id(app, "show", "Open Monet", true, None::<&str>)?;
            let settings_i = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let sep = PredefinedMenuItem::separator(app)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Monet", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &settings_i, &sep, &quit])?;

            let (rgba, w, h) = gauge::render(0.0, TRAY_SIZE);
            TrayIconBuilder::with_id("monet")
                .icon(Image::new_owned(rgba, w, h))
                .title("Monet")
                .tooltip("Monet — loading…")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_panel(app),
                    "settings" => open_settings(app.clone()),
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

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    poll_and_update(&handle).await;
                    let secs = handle
                        .state::<AppState>()
                        .settings
                        .lock()
                        .unwrap()
                        .refresh_secs
                        .max(5);
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(secs)) => {}
                        _ = notify_loop.notified() => {}
                    }
                }
            });

            if std::env::var_os("MONET_SHOW_ON_START").is_some() {
                show_panel(app.handle());
            }
            if std::env::var_os("MONET_SHOW_SETTINGS").is_some() {
                open_settings(app.handle().clone());
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Monet");
}

async fn poll_and_update(app: &AppHandle) {
    {
        let st = app.state::<AppState>();
        st.panel.lock().unwrap().loading = true;
    }
    emit_state(app);

    let auth = app.state::<AppState>().auth.clone();
    let result = auth.usage().await;
    let source = auth.current_source().map(|s| s.as_str().to_string());

    let mode = app.state::<AppState>().settings.lock().unwrap().display_mode.clone();
    let mut tray: Option<(f64, Option<String>)> = None;
    {
        let st = app.state::<AppState>();
        let mut p = st.panel.lock().unwrap();
        p.loading = false;
        p.auth_source = source;
        match result {
            Ok(u) => {
                if let Some(m) = &u.five_hour {
                    tray = Some((m.utilization, tray_label(m.utilization, m.resets_at.as_deref(), &mode)));
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

/// Re-render the tray from cached state (after a display-mode change) without re-fetching.
fn rerender_tray(app: &AppHandle) {
    let st = app.state::<AppState>();
    let mode = st.settings.lock().unwrap().display_mode.clone();
    let session = st.panel.lock().unwrap().session.clone();
    if let Some(m) = session {
        let label = tray_label(m.utilization, m.resets_at.as_deref(), &mode);
        update_tray(app, m.utilization, label);
    }
}

/// Format the tray label per display mode. `None` = no text (gauge icon only).
fn tray_label(utilization: f64, resets_at: Option<&str>, mode: &str) -> Option<String> {
    if mode == "minimal" {
        return None;
    }
    let remaining = resets_at
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| (dt.with_timezone(&chrono::Utc) - chrono::Utc::now()).num_seconds().max(0));
    match remaining {
        Some(secs) => {
            let (h, mn, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
            let t = if mode == "verbose" {
                format!("{h}:{mn:02}:{s:02}")
            } else {
                format!("{h}:{mn:02}")
            };
            Some(format!("{utilization:.0}% {t}"))
        }
        None => Some(format!("{utilization:.0}%")),
    }
}

fn update_tray(app: &AppHandle, pct: f64, label: Option<String>) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(tray) = app.tray_by_id("monet") {
            let (rgba, w, h) = gauge::render(pct, TRAY_SIZE);
            let _ = tray.set_icon(Some(Image::new_owned(rgba, w, h)));
            let _ = tray.set_title(label.as_deref());
            let tip = match &label {
                Some(l) => format!("Monet — {l}"),
                None => format!("Monet — {pct:.0}%"),
            };
            let _ = tray.set_tooltip(Some(&tip));
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
        // On GNOME the closing tray menu can leave the panel shown-but-unfocused,
        // so click-away wouldn't fire until it was first clicked. Re-assert focus
        // once the menu grab has released.
        let app2 = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            let app3 = app2.clone();
            let _ = app2.run_on_main_thread(move || {
                if let Some(w) = app3.get_webview_window("main") {
                    let _ = w.set_focus();
                }
            });
        });
        app.state::<AppState>().notify.notify_one();
    }
}

/// Toggle the panel (left-click on macOS/Windows; Linux uses the menu).
fn toggle_panel(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        if win.is_visible().unwrap_or(false) {
            let _ = win.hide();
            return;
        }
    }
    show_panel(app);
}

// ---- settings persistence + autostart ----

fn settings_path() -> Option<std::path::PathBuf> {
    dirs::config_dir().map(|c| c.join("monet").join("settings.json"))
}

fn load_settings() -> Settings {
    settings_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_settings(s: &Settings) {
    if let Some(p) = settings_path() {
        if let Some(parent) = p.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(s) {
            let _ = std::fs::write(p, json);
        }
    }
}

fn apply_autostart(app: &AppHandle, enable: bool) {
    use tauri_plugin_autostart::ManagerExt;
    let mgr = app.autolaunch();
    let _ = if enable { mgr.enable() } else { mgr.disable() };
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
