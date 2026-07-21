//! Renders the color-coded circular usage gauge into an RGBA image for the tray.
//!
//! Same visual language as the macOS menu-bar gauge: a ring that fills with
//! utilization, the percentage in the center, and the blue/orange/red color
//! thresholds (<75 / 75-89 / >=90).

use resvg::{tiny_skia, usvg};

/// Transparent gap added to the right of the gauge (as a fraction of `size`) so
/// the tray label (percentage + time) doesn't butt right up against the ring.
/// macOS and Linux draw the title immediately after the icon, so the spacing has
/// to live in the image itself.
const RIGHT_PAD_FRAC: f64 = 0.22;

/// Render the gauge for `pct` (0..=100) at `size`x`size` px (plus a transparent
/// right margin), returning `(rgba_bytes, width, height)` suitable for
/// `tauri::image::Image`. The gauge stays square/left-aligned; only the canvas
/// widens.
pub fn render(pct: f64, size: u32) -> (Vec<u8>, u32, u32) {
    let clamped = pct.clamp(0.0, 100.0);
    let color = if clamped >= 90.0 {
        "#ff3b30" // red — critical
    } else if clamped >= 75.0 {
        "#ff9500" // orange — warning
    } else {
        "#0a84ff" // blue — normal
    };

    // Donut-progress trick: a full-circle stroke revealed by dashoffset,
    // rotated so it starts at 12 o'clock and sweeps clockwise.
    let r = 52.0_f64;
    let circ = 2.0 * std::f64::consts::PI * r;
    let offset = circ * (1.0 - clamped / 100.0);
    let label = format!("{clamped:.0}");

    let svg = format!(
        r##"<svg width="{size}" height="{size}" viewBox="0 0 128 128" xmlns="http://www.w3.org/2000/svg">
  <circle cx="64" cy="64" r="52" fill="none" stroke="#8e8e93" stroke-opacity="0.25" stroke-width="12"/>
  <circle cx="64" cy="64" r="52" fill="none" stroke="{color}" stroke-width="12" stroke-linecap="round"
          stroke-dasharray="{circ:.3}" stroke-dashoffset="{offset:.3}" transform="rotate(-90 64 64)"/>
  <text x="64" y="64" text-anchor="middle" dominant-baseline="central"
        font-family="DejaVu Sans, sans-serif" font-size="42" font-weight="bold" fill="{color}">{label}</text>
</svg>"##
    );

    let mut opt = usvg::Options::default();
    opt.fontdb_mut().load_system_fonts();
    let tree = usvg::Tree::from_str(&svg, &opt).expect("gauge svg is valid");

    // Render the (square) gauge into the left of a wider canvas; the extra width
    // on the right is transparent and becomes the gap before the label.
    let width = size + (size as f64 * RIGHT_PAD_FRAC) as u32;
    let mut pixmap = tiny_skia::Pixmap::new(width, size).expect("pixmap alloc");
    resvg::render(&tree, tiny_skia::Transform::identity(), &mut pixmap.as_mut());

    (pixmap.take(), width, size)
}
