#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Monet desktop (Tauri) — tray gauge + drop-down usage panel + settings,
//! driven by real Claude usage data via the shared `monet-core` crate.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use monet_core::{Auth, UsageMetric};
use serde::{Deserialize, Serialize};
use tauri::{
    image::Image,
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, LogicalPosition, Manager, Rect, WebviewUrl, WebviewWindowBuilder,
    WindowEvent,
};
// The tray menu (and its item types) is Linux-only — macOS/Windows open the
// panel directly on click.
#[cfg(target_os = "linux")]
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
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
    /// Epoch ms of the last panel auto-hide (on blur). Lets a tray click that
    /// merely dismissed the panel avoid immediately reopening it.
    last_hidden: AtomicU64,
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

    // One-time migration from the retired native macOS app (same bundle id).
    #[cfg(target_os = "macos")]
    {
        migrate_native_settings(); // fast, no prompt
        let auth_mig = auth.clone();
        // The token import may show a one-time keychain prompt, so run it off the
        // main thread; a later poll picks up the seeded token.
        std::thread::spawn(move || migrate_native_token(&auth_mig));
    }

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
            last_hidden: AtomicU64::new(0),
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
                    window
                        .app_handle()
                        .state::<AppState>()
                        .last_hidden
                        .store(now_ms(), Ordering::Relaxed);
                }
            }
        })
        .setup(move |app| {
            // macOS: run as a menu-bar agent (no Dock icon, LSUIElement-style),
            // matching the native SwiftUI app. Windows still open normally.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let (rgba, w, h) = gauge::render(0.0, TRAY_SIZE);
            let tray = TrayIconBuilder::with_id("monet")
                .icon(Image::new_owned(rgba, w, h))
                .title("Monet")
                .tooltip("Monet — loading…")
                .on_tray_icon_event(|tray, event| {
                    // macOS/Windows: left-click opens the panel right under the icon.
                    // (Linux uses the menu below — AppIndicator can't do click-to-open.)
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        rect,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        // If this same click's blur just dismissed the panel, leave
                        // it closed instead of immediately reopening it.
                        let since = now_ms().saturating_sub(
                            app.state::<AppState>().last_hidden.load(Ordering::Relaxed),
                        );
                        if since >= 250 {
                            show_panel(app, Some(rect));
                        }
                    }
                });

            // Linux (AppIndicator) can't open a window on click and needs a menu to
            // render the icon+label at all, so it keeps the menu. macOS/Windows open
            // the panel directly — Settings and Quit live inside the panel.
            #[cfg(target_os = "linux")]
            let tray = {
                let open = MenuItem::with_id(app, "show", "Open Monet", true, None::<&str>)?;
                let settings_i = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
                let sep = PredefinedMenuItem::separator(app)?;
                let quit = MenuItem::with_id(app, "quit", "Quit Monet", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&open, &settings_i, &sep, &quit])?;
                tray.menu(&menu)
                    .show_menu_on_left_click(true)
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "show" => show_panel(app, None),
                        "settings" => open_settings(app.clone()),
                        "quit" => app.exit(0),
                        _ => {}
                    })
            };

            tray.build(app)?;

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
                show_panel(app.handle(), None);
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

/// Show the panel window and refresh it. `near` is the tray icon's screen rect
/// (from a macOS/Windows click) so the panel drops directly under the icon on the
/// display that holds it; without it (Linux menu / test hook) it falls back to the
/// primary display's top-right.
fn show_panel(app: &AppHandle, near: Option<Rect>) {
    if let Some(win) = app.get_webview_window("main") {
        match near {
            Some(rect) => position_under_icon(&win, rect),
            None => position_top_right(&win),
        }
        // macOS: as a menu-bar agent the popover must float above other apps'
        // windows — an Accessory app won't bring it forward on its own.
        #[cfg(target_os = "macos")]
        let _ = win.set_always_on_top(true);
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

/// Drop the panel directly under the tray icon, on whatever display holds it,
/// clamped to that display so it stays fully on-screen.
/// One monitor's geometry as Tauri reports it on macOS: origin in **points**,
/// size in **physical px**, plus the scale factor. (This mixed convention is
/// exactly what `Monitor::position()`/`size()`/`scale_factor()` return.)
struct MonitorGeom {
    x: f64,
    y: f64,
    w_phys: f64,
    h_phys: f64,
    scale: f64,
}

/// Compute the panel's top-left in **global points** so it sits centered just
/// under a tray icon, given the icon's raw rect — which macOS reports as
/// `global_points × the icon display's scale` — and every monitor's geometry.
///
/// Works for any arrangement (any count, resolution, scale, side-by-side,
/// stacked, or displays at negative coordinates): recover the icon's global
/// points on each candidate display by dividing by that display's scale, keep
/// the candidates whose points rect actually contains the icon, and break ties
/// (overlapping scaled ranges on mixed-DPI setups) by whichever scale yields the
/// most menu-bar-like icon height. Returns `None` if the icon can't be localized.
fn panel_origin_points(
    rect_x: f64,
    rect_y: f64,
    rect_w: f64,
    rect_h: f64,
    panel_w: f64,
    monitors: &[MonitorGeom],
) -> Option<(f64, f64)> {
    let (m, gx, gy) = monitors
        .iter()
        .filter_map(|m| {
            let gx = rect_x / m.scale;
            let gy = rect_y / m.scale;
            let mw = m.w_phys / m.scale;
            let mh = m.h_phys / m.scale;
            let inside = gx >= m.x && gx <= m.x + mw && gy >= m.y && gy <= m.y + mh;
            inside.then_some((m, gx, gy))
        })
        .min_by(|a, b| {
            // Prefer the display whose menu bar (top edge) the icon sits on — this
            // disambiguates vertically stacked displays that share an edge — then
            // the scale that yields the most menu-bar-like icon height, which
            // disambiguates overlapping scaled ranges on side-by-side mixed-DPI.
            let score = |c: &(&MonitorGeom, f64, f64)| {
                let (m, _gx, gy) = *c;
                ((gy - m.y).abs(), (rect_h / m.scale - 24.0).abs())
            };
            let (ay, ah) = score(a);
            let (by, bh) = score(b);
            ay.partial_cmp(&by)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(ah.partial_cmp(&bh).unwrap_or(std::cmp::Ordering::Equal))
        })?;

    let iw = rect_w / m.scale;
    let ih = rect_h / m.scale;
    let mw = m.w_phys / m.scale;
    let x = gx + iw / 2.0 - panel_w / 2.0; // centered under the icon
    let y = gy + ih + 4.0; // just below it
    let min_x = m.x + 4.0;
    let max_x = (m.x + mw - panel_w - 4.0).max(min_x);
    Some((x.clamp(min_x, max_x), y))
}

fn position_under_icon(win: &tauri::WebviewWindow, rect: Rect) {
    let rp = rect.position.to_physical::<f64>(1.0);
    let rs = rect.size.to_physical::<f64>(1.0);
    let monitors: Vec<MonitorGeom> = win
        .available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| MonitorGeom {
            x: m.position().x as f64,
            y: m.position().y as f64,
            w_phys: m.size().width as f64,
            h_phys: m.size().height as f64,
            scale: m.scale_factor(),
        })
        .collect();

    match panel_origin_points(rp.x, rp.y, rs.width, rs.height, PANEL_WIDTH, &monitors) {
        Some((x, y)) => {
            #[cfg(debug_assertions)]
            eprintln!("[monet] panel logical ({x:.0},{y:.0})");
            let _ = win.set_position(LogicalPosition::new(x, y));
        }
        None => position_top_right(win), // couldn't localize the icon — safe fallback
    }
}

/// Fallback position (Linux menu / test hook): primary display, top-right.
fn position_top_right(win: &tauri::WebviewWindow) {
    if let Ok(Some(monitor)) = win.primary_monitor() {
        let scale = monitor.scale_factor();
        let logical_w = monitor.size().width as f64 / scale;
        let x = (logical_w - PANEL_WIDTH - 8.0).max(8.0);
        let _ = win.set_position(LogicalPosition::new(x, 36.0));
    }
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

// ---- one-time migration from the native macOS app (shares the bundle id) ----

/// Import the native SwiftUI app's menu-bar settings from the shared
/// `com.monet.usage-monitor` `UserDefaults` domain on first launch after
/// migrating. `defaults` reads the same domain the native app wrote (we share
/// the bundle id) and never prompts.
#[cfg(target_os = "macos")]
fn migrate_native_settings() {
    // First launch only — never overwrite settings the user already has.
    if settings_path().map(|p| p.exists()).unwrap_or(true) {
        return;
    }
    let read = |key: &str| -> Option<String> {
        let out = std::process::Command::new("defaults")
            .args(["read", "com.monet.usage-monitor", key])
            .output()
            .ok()?;
        let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
        (out.status.success() && !s.is_empty()).then_some(s)
    };

    // Native raw values are "Minimal"/"Normal"/"Verbose"; Tauri uses lowercase.
    let mode = read("menuBarDisplayMode").map(|m| m.to_lowercase());
    let secs = read("refreshInterval")
        .and_then(|s| s.parse::<f64>().ok())
        .map(|f| f.round() as u64);
    if mode.is_none() && secs.is_none() {
        return; // nothing to import
    }

    let mut s = Settings::default();
    if let Some(m) = mode {
        if ["minimal", "normal", "verbose"].contains(&m.as_str()) {
            s.display_mode = m;
        }
    }
    if let Some(sec) = secs {
        if sec >= 5 {
            s.refresh_secs = sec;
        }
    }
    save_settings(&s);
}

/// Import the native app's own OAuth token from the shared Keychain item
/// (service `com.monet.usage-monitor`, account `default`) so a user who signed
/// in via Monet's own browser flow (not Claude Code) isn't logged out by the
/// migration. Best-effort — macOS may prompt once for keychain access; on any
/// failure the user simply re-signs-in. Claude Code users are unaffected either
/// way (both apps read `~/.claude/.credentials.json`).
#[cfg(target_os = "macos")]
fn migrate_native_token(auth: &Auth) {
    if auth.has_own_oauth() {
        return;
    }
    let out = std::process::Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            "com.monet.usage-monitor",
            "-a",
            "default",
            "-w",
        ])
        .output();
    let Ok(out) = out else { return };
    let Ok(json) = String::from_utf8(out.stdout) else { return };
    if !out.status.success() {
        return;
    }
    if let Some((access, refresh, obtained, expires)) = parse_native_oauth_json(json.trim()) {
        auth.seed_own_oauth(access, refresh, obtained, expires);
    }
}

/// Convert the native app's Keychain `OAuthTokens` JSON into
/// `(access, refresh, obtained_at_unix, expires_in)`. Swift's default `Date`
/// encoding is seconds since 2001-01-01, so `obtainedAt` is shifted by
/// 978307200s to a Unix timestamp.
#[cfg(any(target_os = "macos", test))]
fn parse_native_oauth_json(json: &str) -> Option<(String, Option<String>, i64, i64)> {
    #[derive(Deserialize)]
    struct NativeTokens {
        #[serde(rename = "accessToken")]
        access_token: String,
        #[serde(rename = "refreshToken")]
        refresh_token: Option<String>,
        #[serde(rename = "expiresIn")]
        expires_in: f64,
        #[serde(rename = "obtainedAt")]
        obtained_at: f64,
    }
    let t: NativeTokens = serde_json::from_str(json).ok()?;
    let obtained_unix = (t.obtained_at + 978_307_200.0).round() as i64;
    Some((
        t.access_token,
        t.refresh_token,
        obtained_unix,
        t.expires_in.round() as i64,
    ))
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

#[cfg(test)]
mod tests {
    use super::{panel_origin_points, MonitorGeom};

    const PANEL: f64 = 360.0;

    fn geom(x: f64, y: f64, w_phys: f64, h_phys: f64, scale: f64) -> MonitorGeom {
        MonitorGeom { x, y, w_phys, h_phys, scale }
    }

    /// A tray rect the way macOS reports it: global points × the icon display's
    /// scale, with a ~24pt-tall menu-bar icon `w_pts` wide sitting at the top.
    fn rect_for(icon_pts_x: f64, icon_pts_y: f64, w_pts: f64, scale: f64) -> (f64, f64, f64, f64) {
        (icon_pts_x * scale, icon_pts_y * scale, w_pts * scale, 24.0 * scale)
    }

    fn assert_in(x: f64, lo: f64, hi: f64, msg: &str) {
        assert!(x >= lo && x <= hi, "{msg}: x={x} not in [{lo},{hi}]");
    }

    // The user's actual setup: built-in retina (points 0..1512, scale 2) with a
    // 1080p external to the right (points 1512..3432, scale 1).
    #[test]
    fn builtin_plus_external_to_right_mixed_dpi() {
        let mons = vec![geom(0., 0., 3024., 1964., 2.), geom(1512., 0., 1920., 1080., 1.)];
        // icon near the right of the BUILT-IN menu bar
        let (rx, ry, rw, rh) = rect_for(1231., 0., 100., 2.);
        let (x, y) = panel_origin_points(rx, ry, rw, rh, PANEL, &mons).unwrap();
        assert_in(x, 0., 1512. - PANEL, "built-in");
        assert!(y > 0. && y < 60.);
        // icon near the right of the EXTERNAL menu bar
        let (rx, ry, rw, rh) = rect_for(3149., 0., 100., 1.);
        let (x, _) = panel_origin_points(rx, ry, rw, rh, PANEL, &mons).unwrap();
        assert_in(x, 1512., 3432. - PANEL, "external");
    }

    #[test]
    fn single_retina_monitor() {
        let mons = vec![geom(0., 0., 2560., 1600., 2.)]; // points 0..1280
        let (rx, ry, rw, rh) = rect_for(1000., 0., 90., 2.);
        let (x, _) = panel_origin_points(rx, ry, rw, rh, PANEL, &mons).unwrap();
        assert_in(x, 0., 1280. - PANEL, "single");
    }

    #[test]
    fn vertically_stacked_shares_edge() {
        // top (points y 0..900) over bottom (y 900..1800), both 1440 wide scale 1
        let mons = vec![geom(0., 0., 1440., 900., 1.), geom(0., 900., 1440., 900., 1.)];
        // icon on the BOTTOM monitor's menu bar (its top edge, y=900)
        let (rx, ry, rw, rh) = rect_for(700., 900., 100., 1.);
        let (x, y) = panel_origin_points(rx, ry, rw, rh, PANEL, &mons).unwrap();
        assert_in(x, 0., 1440. - PANEL, "stacked-x");
        assert!(y >= 900. && y < 960., "should drop below the bottom bar, got {y}");
    }

    #[test]
    fn monitor_to_the_left_negative_coords() {
        // external at points x -1920..0 (scale 1), built-in at 0..1512 (scale 2)
        let mons = vec![geom(-1920., 0., 1920., 1080., 1.), geom(0., 0., 3024., 1964., 2.)];
        let (rx, ry, rw, rh) = rect_for(-100., 0., 100., 1.);
        let (x, _) = panel_origin_points(rx, ry, rw, rh, PANEL, &mons).unwrap();
        assert_in(x, -1920., -PANEL, "left-monitor");
    }

    #[test]
    fn three_monitors_mixed_dpi_center_retina() {
        let mons = vec![
            geom(-1920., 0., 1920., 1080., 1.), // left
            geom(0., 0., 3024., 1964., 2.),     // center retina
            geom(1512., 0., 1920., 1080., 1.),  // right
        ];
        let (rx, ry, rw, rh) = rect_for(800., 0., 100., 2.); // icon on center
        let (x, _) = panel_origin_points(rx, ry, rw, rh, PANEL, &mons).unwrap();
        assert_in(x, 0., 1512. - PANEL, "center");
    }

    #[test]
    fn no_monitors_returns_none() {
        assert!(panel_origin_points(100., 0., 100., 24., PANEL, &[]).is_none());
    }

    #[test]
    fn native_oauth_json_converts_swift_date() {
        use super::parse_native_oauth_json;
        // Swift default-encodes Date as seconds since 2001-01-01; Unix is +978307200.
        let json = r#"{"accessToken":"AT","refreshToken":"RT","expiresIn":3600,"tokenType":"Bearer","obtainedAt":774000000}"#;
        let (a, r, obtained, exp) = parse_native_oauth_json(json).unwrap();
        assert_eq!(a, "AT");
        assert_eq!(r.as_deref(), Some("RT"));
        assert_eq!(obtained, 774_000_000 + 978_307_200);
        assert_eq!(exp, 3600);

        // No refresh token, fractional expiresIn, obtainedAt at the epoch shift.
        let json2 = r#"{"accessToken":"AT","expiresIn":100.7,"tokenType":"Bearer","obtainedAt":0}"#;
        let (_, r2, ob2, exp2) = parse_native_oauth_json(json2).unwrap();
        assert!(r2.is_none());
        assert_eq!(ob2, 978_307_200);
        assert_eq!(exp2, 101);
    }
}
