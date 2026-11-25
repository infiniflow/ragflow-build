use std::ffi::CString;
use std::os::raw::c_char;
use std::path::Path;
use std::slice;
use std::sync::{Arc, OnceLock};

use resvg::tiny_skia::{Color, Pixmap, Transform};
use resvg::usvg::{fontdb, ImageHrefResolver, Options, Tree};

const DEFAULT_MAX_SIDE: u32 = 2048;
const DEFAULT_MAX_PIXELS: u64 = 10_000_000;

// Font files a Windows install ships, in a deterministic fallback order:
// Microsoft YaHei (Latin + Simplified Chinese in one sans face), SimSun / SimHei
// as the CJK fallbacks, then the Latin faces every install carries.
#[cfg(target_os = "windows")]
const WINDOWS_FONT_FILES: &[&str] = &[
    "msyh.ttc",
    "msyhbd.ttc",
    "msyhl.ttc",
    "simsun.ttc",
    "simhei.ttf",
    "segoeui.ttf",
    "segoeuib.ttf",
    "seguisym.ttf",
    "seguiemj.ttf",
    "arial.ttf",
    "arialbd.ttf",
    "calibri.ttf",
    "tahoma.ttf",
    "times.ttf",
    "timesbd.ttf",
    "cour.ttf",
    "consola.ttf",
];

/// Directories Windows keeps faces in: the machine-wide `%WINDIR%\Fonts` and the
/// per-user `%LOCALAPPDATA%\Microsoft\Windows\Fonts` written by "Install for me".
/// Resolved at runtime so a relocated Windows directory is still found.
#[cfg(target_os = "windows")]
fn windows_font_dirs() -> Vec<std::path::PathBuf> {
    let root = std::env::var_os("WINDIR")
        .or_else(|| std::env::var_os("SystemRoot"))
        .unwrap_or_else(|| std::ffi::OsString::from("C:\\Windows"));
    let mut dirs = vec![Path::new(&root).join("Fonts")];
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        dirs.push(
            Path::new(&local)
                .join("Microsoft")
                .join("Windows")
                .join("Fonts"),
        );
    }
    dirs
}

// Preferred generic families, most wanted first. Windows lists its own faces
// ahead of the unix names so a stock install picks a CJK sans instead of falling
// through to the fontdb default. The non-Windows lists are unchanged: the
// fallback order that ships on Linux/macOS must stay byte-identical to what they
// already render with.
#[cfg(target_os = "windows")]
const PREFERRED_SANS: &[&str] = &[
    "Microsoft YaHei UI",
    "Microsoft YaHei",
    "Microsoft JhengHei",
    "SimHei",
    "Segoe UI",
    "Arial",
    "Noto Sans CJK SC",
    "Carlito",
    "Liberation Sans",
    "DejaVu Sans",
];
#[cfg(not(target_os = "windows"))]
const PREFERRED_SANS: &[&str] = &[
    "Noto Sans CJK SC",
    "Noto Sans SC",
    "Carlito",
    "Liberation Sans",
    "DejaVu Sans",
    "WenQuanYi Zen Hei",
    "Arial",
    "Helvetica",
];

#[cfg(target_os = "windows")]
const PREFERRED_SERIF: &[&str] = &[
    "SimSun",
    "Times New Roman",
    "Caladea",
    "Liberation Serif",
    "DejaVu Serif",
];
#[cfg(not(target_os = "windows"))]
const PREFERRED_SERIF: &[&str] = &[
    "Caladea",
    "Liberation Serif",
    "DejaVu Serif",
    "Times New Roman",
];

#[cfg(target_os = "windows")]
const PREFERRED_MONO: &[&str] = &[
    "Consolas",
    "Courier New",
    "Liberation Mono",
    "DejaVu Sans Mono",
];
#[cfg(not(target_os = "windows"))]
const PREFERRED_MONO: &[&str] = &[
    "Noto Sans Mono CJK SC",
    "Liberation Mono",
    "DejaVu Sans Mono",
    "Courier New",
];

struct FontState {
    db: Arc<fontdb::Database>,
    default_sans: String,
}

static FONT_STATE: OnceLock<FontState> = OnceLock::new();

fn load_dir_matching(db: &mut fontdb::Database, dir: &str) {
    let path = Path::new(dir);
    if !path.is_dir() {
        return;
    }
    if let Ok(entries) = std::fs::read_dir(path) {
        let mut files: Vec<_> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.is_file()
                    && matches!(
                        p.extension()
                            .and_then(|s| s.to_str())
                            .map(|s| s.to_ascii_lowercase())
                            .as_deref(),
                        Some("ttf" | "otf" | "ttc")
                    )
            })
            .collect();
        files.sort();
        for f in files {
            let _ = db.load_font_file(f);
        }
    }
}

fn build_font_state() -> FontState {
    let mut db = fontdb::Database::new();

    // Load a curated, deterministic font set first so fallback order is predictable
    // and desktop/sample fonts (e.g. unifont_sample) cannot hijack CJK rendering.
    // Keep CJK fonts sans-serif so diagrams render Chinese in crisp sans-serif.
    let explicit_files = [
        "/usr/local/share/fonts/truetype/noto/NotoSansCJKsc-VF.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    ];
    for p in explicit_files {
        if Path::new(p).is_file() {
            let _ = db.load_font_file(p);
        }
    }

    let curated_dirs = [
        "/usr/local/share/fonts/truetype/noto",
        "/usr/share/fonts/truetype/crosextra", // Carlito (Calibri) & Caladea (Cambria)
        "/usr/share/fonts/truetype/liberation",
        "/usr/share/fonts/truetype/liberation2",
        "/usr/share/fonts/truetype/dejavu",
    ];
    for dir in curated_dirs {
        load_dir_matching(&mut db, dir);
    }

    // Windows has no fontconfig and none of the paths above, so load a fixed list
    // out of the Windows font directories instead of walking them: %WINDIR%\Fonts
    // holds several hundred faces, and parsing all of them would cost far more
    // memory and startup time than the handful a diagram can reference.
    #[cfg(target_os = "windows")]
    {
        for dir in windows_font_dirs() {
            for file in WINDOWS_FONT_FILES {
                let path = dir.join(file);
                if path.is_file() {
                    let _ = db.load_font_file(&path);
                }
            }
        }
    }

    // macOS / minimal host fallback when none of the curated paths exist.
    if db.is_empty() {
        db.load_system_fonts();
    }

    // Prefer a CJK-capable sans-serif as the default fallback family when present
    // (Noto Sans CJK SC / Microsoft YaHei contain crisp Latin + Simplified Chinese
    // glyphs together), falling back to Latin metric-compatible sans-serifs.
    let mut default_sans = "sans-serif".to_string();
    for &fam in PREFERRED_SANS {
        if has_family(&db, fam) {
            db.set_sans_serif_family(fam);
            default_sans = fam.to_string();
            break;
        }
    }
    for &fam in PREFERRED_SERIF {
        if has_family(&db, fam) {
            db.set_serif_family(fam);
            break;
        }
    }
    for &fam in PREFERRED_MONO {
        if has_family(&db, fam) {
            db.set_monospace_family(fam);
            break;
        }
    }

    FontState {
        db: Arc::new(db),
        default_sans,
    }
}

fn has_family(db: &fontdb::Database, name: &str) -> bool {
    db.faces()
        .any(|f| f.families.iter().any(|(fam, _)| fam.eq_ignore_ascii_case(name)))
}

fn get_font_state() -> &'static FontState {
    FONT_STATE.get_or_init(build_font_state)
}

fn compute_target_size(src_w: f32, src_h: f32, max_side: u32, max_pixels: u64) -> Option<(u32, u32)> {
    if !(src_w.is_finite() && src_h.is_finite() && src_w > 0.0 && src_h > 0.0) {
        return None;
    }
    let max_side = if max_side == 0 { DEFAULT_MAX_SIDE } else { max_side } as f64;
    let max_pixels = if max_pixels == 0 { DEFAULT_MAX_PIXELS } else { max_pixels } as f64;

    let w = src_w as f64;
    let h = src_h as f64;
    let mut scale = max_side / w.max(h);

    let projected_pixels = (w * scale) * (h * scale);
    if projected_pixels > max_pixels {
        scale *= (max_pixels / projected_pixels).sqrt();
    }

    let out_w = (w * scale).round().max(1.0) as u32;
    let out_h = (h * scale).round().max(1.0) as u32;
    if (out_w as u64) * (out_h as u64) == 0 {
        return None;
    }
    Some((out_w, out_h))
}

fn set_error(out_err: *mut *mut c_char, msg: &str) {
    if out_err.is_null() {
        return;
    }
    let clean = msg.replace('\0', " ");
    if let Ok(cs) = CString::new(clean) {
        unsafe {
            *out_err = cs.into_raw();
        }
    }
}

fn render_svg_to_png_impl(
    svg_bytes: &[u8],
    max_side: u32,
    max_pixels: u64,
) -> Result<Vec<u8>, String> {
    let state = get_font_state();

    // Block all external file/network image references (SSRF/LFI hardening);
    // allow only inline data: URIs.
    let resolver = ImageHrefResolver {
        resolve_data: ImageHrefResolver::default_data_resolver(),
        resolve_string: Box::new(|_, _| None),
    };

    let opt = Options {
        resources_dir: None,
        fontdb: state.db.clone(),
        font_family: state.default_sans.clone(),
        image_href_resolver: resolver,
        ..Options::default()
    };

    let tree = Tree::from_data(svg_bytes, &opt).map_err(|e| format!("parse svg: {e}"))?;
    let size = tree.size();
    let (out_w, out_h) = compute_target_size(size.width(), size.height(), max_side, max_pixels)
        .ok_or_else(|| format!("invalid svg dimensions: {}x{}", size.width(), size.height()))?;

    let mut pixmap = Pixmap::new(out_w, out_h)
        .ok_or_else(|| format!("allocate pixmap {}x{} failed", out_w, out_h))?;
    pixmap.fill(Color::WHITE);

    let sx = (out_w as f32) / size.width();
    let sy = (out_h as f32) / size.height();
    let transform = Transform::from_scale(sx, sy);
    resvg::render(&tree, transform, &mut pixmap.as_mut());

    pixmap.encode_png().map_err(|e| format!("encode png: {e}"))
}

#[no_mangle]
pub extern "C" fn svgrender_render_png(
    svg_data: *const u8,
    svg_len: usize,
    max_side: u32,
    max_pixels: u64,
    out_png: *mut *mut u8,
    out_len: *mut usize,
    out_err: *mut *mut c_char,
) -> i32 {
    if !out_png.is_null() {
        unsafe { *out_png = std::ptr::null_mut() };
    }
    if !out_len.is_null() {
        unsafe { *out_len = 0 };
    }
    if !out_err.is_null() {
        unsafe { *out_err = std::ptr::null_mut() };
    }

    if svg_data.is_null() || svg_len == 0 || out_png.is_null() || out_len.is_null() {
        set_error(out_err, "invalid arguments");
        return -1;
    }

    let result = std::panic::catch_unwind(|| {
        let svg_bytes = unsafe { slice::from_raw_parts(svg_data, svg_len) };
        render_svg_to_png_impl(svg_bytes, max_side, max_pixels)
    });

    match result {
        Ok(Ok(png)) => {
            let mut boxed = png.into_boxed_slice();
            let len = boxed.len();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe {
                *out_png = ptr;
                *out_len = len;
            }
            0
        }
        Ok(Err(msg)) => {
            set_error(out_err, &msg);
            -1
        }
        Err(_) => {
            set_error(out_err, "resvg panicked while rendering svg");
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn svgrender_free_bytes(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        let _ = Box::from_raw(slice::from_raw_parts_mut(ptr, len));
    }
}

#[no_mangle]
pub extern "C" fn svgrender_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}
