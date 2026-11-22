//! Updates: find the newest published desktop release on GitHub. When the
//! release carries a signed update manifest (`latest.json`) for this Mac, Sure
//! downloads the update itself, verifies its signature against the public key
//! in `tauri.conf.json`, replaces the app bundle in place and restarts. A
//! download made by Sure is not quarantined, so macOS does not block the new
//! version the way it blocks a DMG downloaded in the browser. Releases without
//! a manifest fall back to opening the DMG in the browser. User data lives
//! outside the app bundle either way, so it is kept.

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Duration;
use tauri::menu::MenuItem;
use tauri::{Emitter, Manager, Wry};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_updater::UpdaterExt;

/// `owner/repo` whose releases are checked, set at build time by CI. Builds
/// without it (local and dev builds) never check.
const UPDATE_REPO: Option<&str> = match option_env!("SURE_UPDATE_REPO") {
    Some(repo) if !repo.is_empty() => Some(repo),
    _ => None,
};
const TAG_PREFIX: &str = "desktop-v";
/// Release asset with the signed update for each platform (Tauri's static
/// update manifest format).
const MANIFEST_ASSET: &str = "latest.json";
const FIRST_CHECK_DELAY: Duration = Duration::from_secs(20);
const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

pub const MENU_ID: &str = "check_updates";
pub const MENU_CHECK_LABEL: &str = "Check for Updates…";

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub enabled: bool,
    pub current: String,
    pub checking: bool,
    pub checked: bool,
    pub available: bool,
    pub latest: Option<String>,
    pub download_url: Option<String>,
    pub release_url: Option<String>,
    /// The release has a signed update Sure can install itself.
    pub installable: bool,
    pub installing: bool,
    /// Download progress of an in-app install, 0.0 to 1.0, when known.
    pub progress: Option<f64>,
    pub error: Option<String>,
    #[serde(skip)]
    manifest_url: Option<String>,
}

#[derive(Default)]
pub struct UpdateState {
    info: Mutex<UpdateInfo>,
    menu_item: Mutex<Option<MenuItem<Wry>>>,
    notified_version: Mutex<Option<String>>,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    html_url: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Deserialize, Clone)]
struct Asset {
    name: String,
    browser_download_url: String,
}

struct Latest {
    version: String,
    download_url: Option<String>,
    manifest_url: Option<String>,
    release_url: String,
}

pub fn setup(app: &tauri::AppHandle, menu_item: MenuItem<Wry>) {
    let state = app.state::<UpdateState>();
    *state.menu_item.lock().unwrap() = Some(menu_item);
    {
        let mut info = state.info.lock().unwrap();
        info.enabled = UPDATE_REPO.is_some();
        info.current = app.package_info().version.to_string();
    }
    if UPDATE_REPO.is_none() || cfg!(debug_assertions) {
        return;
    }
    let handle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(FIRST_CHECK_DELAY);
        loop {
            run_check(&handle);
            std::thread::sleep(CHECK_INTERVAL);
        }
    });
}

/// Menu action: install (or download) the update if one is known, otherwise
/// check now. Preferences opens either way, since it shows the progress and
/// the result.
pub fn on_menu(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("prefs") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
    let info = app.state::<UpdateState>().info.lock().unwrap().clone();
    if info.available && info.installable {
        start_install(app);
        return;
    }
    if info.available {
        if let Err(e) = open_download(&info) {
            eprintln!("[sure] could not open the update download: {e}");
        }
        return;
    }
    let handle = app.clone();
    std::thread::spawn(move || run_check(&handle));
}

/// Check GitHub for a newer release, record the result and tell the UI.
pub fn run_check(app: &tauri::AppHandle) -> UpdateInfo {
    let state = app.state::<UpdateState>();
    let Some(repo) = UPDATE_REPO else {
        return state.info.lock().unwrap().clone();
    };
    if state.info.lock().unwrap().installing {
        return state.info.lock().unwrap().clone();
    }
    set_info(app, |i| {
        i.checking = true;
        i.error = None;
    });
    let current = app.package_info().version.to_string();
    let result = fetch_latest(repo, &current);
    let info = set_info(app, |i| {
        i.checking = false;
        i.checked = true;
        match result {
            Ok(Some(latest)) => {
                i.available = is_newer(&latest.version, &current);
                i.latest = Some(latest.version);
                i.download_url = latest.download_url;
                i.installable = latest.manifest_url.is_some();
                i.manifest_url = latest.manifest_url;
                i.release_url = Some(latest.release_url);
            }
            Ok(None) => {
                i.available = false;
                i.latest = None;
                i.download_url = None;
                i.installable = false;
                i.manifest_url = None;
                i.release_url = None;
            }
            Err(e) => i.error = Some(e),
        }
    });
    if info.available {
        announce(app, &info);
    }
    info
}

fn set_info(app: &tauri::AppHandle, f: impl FnOnce(&mut UpdateInfo)) -> UpdateInfo {
    let state = app.state::<UpdateState>();
    let info = {
        let mut info = state.info.lock().unwrap();
        f(&mut info);
        info.clone()
    };
    let _ = app.emit("updates://changed", info.clone());
    info
}

/// Relabel the menu item and send one notification per new version.
fn announce(app: &tauri::AppHandle, info: &UpdateInfo) {
    let Some(version) = info.latest.clone() else { return };
    let state = app.state::<UpdateState>();
    if let Some(item) = state.menu_item.lock().unwrap().as_ref() {
        let label = if info.installable {
            format!("Install Sure {version}…")
        } else {
            format!("Download Sure {version}…")
        };
        let _ = item.set_text(label);
    }
    let mut notified = state.notified_version.lock().unwrap();
    if notified.as_deref() == Some(version.as_str()) {
        return;
    }
    *notified = Some(version.clone());
    let _ = app
        .notification()
        .builder()
        .title(format!("Sure {version} is available"))
        .body(if info.installable {
            "Choose Install Sure in the Sure menu to update and restart."
        } else {
            "Choose Download Sure in the Sure menu to get it."
        })
        .show();
}

fn fetch_latest(repo: &str, current: &str) -> Result<Option<Latest>, String> {
    let url = format!("https://api.github.com/repos/{repo}/releases?per_page=30");
    let releases: Vec<Release> = ureq::get(&url)
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", &format!("Sure-Desktop/{current}"))
        .timeout(Duration::from_secs(15))
        .call()
        .map_err(|e| match e {
            ureq::Error::Status(code, _) => format!("GitHub answered {code}"),
            other => other.to_string(),
        })?
        .into_json()
        .map_err(|e| e.to_string())?;
    Ok(pick_latest(releases, asset_name_for_this_platform()))
}

fn pick_latest(releases: Vec<Release>, wanted_asset: Option<&str>) -> Option<Latest> {
    releases
        .into_iter()
        .filter(|r| !r.draft && !r.prerelease)
        .filter_map(|r| {
            let version = r.tag_name.strip_prefix(TAG_PREFIX)?.to_string();
            parse_version(&version)?;
            // DMGs are attached a while after a release is published; until
            // this Mac's is there, the release isn't offered.
            let asset_url = |name: &str| {
                r.assets.iter().find(|a| a.name == name).map(|a| a.browser_download_url.clone())
            };
            let download_url = match wanted_asset {
                Some(name) => Some(asset_url(name)?),
                None => None,
            };
            // Only where this platform's DMG is published too: the manifest
            // is uploaded with the DMGs.
            let manifest_url = wanted_asset.and_then(|_| asset_url(MANIFEST_ASSET));
            Some(Latest { version, download_url, manifest_url, release_url: r.html_url })
        })
        .max_by(|a, b| parse_version(&a.version).cmp(&parse_version(&b.version)))
}

/// The release asset built for this Mac: the release workflow uploads one DMG
/// per architecture under these stable names.
fn asset_name_for_this_platform() -> Option<&'static str> {
    if cfg!(target_os = "macos") {
        match std::env::consts::ARCH {
            "aarch64" => Some("Sure-macOS-arm64.dmg"),
            "x86_64" => Some("Sure-macOS-x86_64.dmg"),
            _ => None,
        }
    } else {
        None
    }
}

/// `major.minor.patch`, ignoring any pre-release or build suffix.
fn parse_version(v: &str) -> Option<(u64, u64, u64)> {
    let core = v.split(['-', '+']).next()?;
    let mut parts = core.split('.').map(|p| p.parse::<u64>().ok());
    let version = (parts.next()??, parts.next()??, parts.next()??);
    parts.next().is_none().then_some(version)
}

fn is_newer(candidate: &str, current: &str) -> bool {
    match (parse_version(candidate), parse_version(current)) {
        (Some(c), Some(cur)) => c > cur,
        _ => false,
    }
}

fn open_download(info: &UpdateInfo) -> Result<(), String> {
    let url = info
        .download_url
        .as_ref()
        .or(info.release_url.as_ref())
        .ok_or("no update to download")?;
    // Only ever hand GitHub release links to the browser.
    if !url.starts_with("https://github.com/") {
        return Err("unexpected download address".into());
    }
    open::that(url).map_err(|e| e.to_string())
}

/// Download, verify and install the update on a background task, then
/// restart into it. Progress and failures show through `updates://changed`.
fn start_install(app: &tauri::AppHandle) {
    {
        let state = app.state::<UpdateState>();
        let mut info = state.info.lock().unwrap();
        if info.installing || !info.installable {
            return;
        }
        info.installing = true;
    }
    set_info(app, |i| {
        i.error = None;
        i.progress = None;
    });
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        match install(&handle).await {
            Ok(()) => {
                // The new bundle is in place; the running services still use
                // the old files. Stop them like quitting does, then relaunch.
                crate::local_backend::stop(&handle);
                handle.restart();
            }
            Err(e) => {
                eprintln!("[sure] update failed: {e}");
                set_info(&handle, |i| {
                    i.installing = false;
                    i.progress = None;
                    i.error = Some(e);
                });
            }
        }
    });
}

async fn install(app: &tauri::AppHandle) -> Result<(), String> {
    let manifest = app
        .state::<UpdateState>()
        .info
        .lock()
        .unwrap()
        .manifest_url
        .clone()
        .ok_or("no update to install")?;
    // The manifest comes from this repository's releases only.
    if !manifest.starts_with("https://github.com/") {
        return Err("unexpected update address".into());
    }
    let url = url::Url::parse(&manifest).map_err(|e| e.to_string())?;
    let update = app
        .updater_builder()
        .endpoints(vec![url])
        .map_err(|e| e.to_string())?
        .build()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?
        .ok_or("Sure is already up to date")?;
    let mut received: u64 = 0;
    let handle = app.clone();
    let bytes = update
        .download(
            move |chunk, total| {
                let before = received;
                received += chunk as u64;
                if let Some(total) = total.filter(|t| *t > 0) {
                    // Emit about once per percent, not once per chunk.
                    if before * 100 / total != received * 100 / total {
                        let p = (received as f64 / total as f64).min(1.0);
                        set_info(&handle, |i| i.progress = Some(p));
                    }
                }
            },
            || {},
        )
        .await
        .map_err(|e| e.to_string())?;
    update.install(bytes).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn install_update(app: tauri::AppHandle) {
    start_install(&app);
}

#[tauri::command]
pub fn update_status(app: tauri::AppHandle) -> UpdateInfo {
    app.state::<UpdateState>().info.lock().unwrap().clone()
}

#[tauri::command]
pub async fn check_for_updates(app: tauri::AppHandle) -> Result<UpdateInfo, String> {
    tauri::async_runtime::spawn_blocking(move || run_check(&app))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn download_update(app: tauri::AppHandle) -> Result<(), String> {
    let info = app.state::<UpdateState>().info.lock().unwrap().clone();
    open_download(&info)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str, assets: &[&str]) -> Release {
        Release {
            tag_name: tag.into(),
            html_url: format!("https://github.com/o/r/releases/tag/{tag}"),
            draft: false,
            prerelease: false,
            assets: assets
                .iter()
                .map(|n| Asset {
                    name: (*n).into(),
                    browser_download_url: format!("https://github.com/o/r/releases/download/{tag}/{n}"),
                })
                .collect(),
        }
    }

    #[test]
    fn compares_versions_numerically() {
        assert!(is_newer("0.1.10", "0.1.9"));
        assert!(is_newer("0.2.0", "0.1.99"));
        assert!(!is_newer("0.1.9", "0.1.9"));
        assert!(!is_newer("0.1.8", "0.1.9"));
        assert!(!is_newer("garbage", "0.1.9"));
        assert!(is_newer("0.1.1", "0.1.0-ci.17"));
    }

    #[test]
    fn picks_highest_desktop_release_and_its_asset() {
        let mut draft = release("desktop-v0.1.99", &[]);
        draft.draft = true;
        let releases = vec![
            release("v2026.11.14-alpha", &["Sure.dmg"]),
            draft,
            release("desktop-v0.1.9", &["Sure-macOS-arm64.dmg"]),
            release("desktop-v0.1.12", &["Sure-macOS-arm64.dmg", "Sure-macOS-x86_64.dmg"]),
        ];
        let latest = pick_latest(releases, Some("Sure-macOS-arm64.dmg")).unwrap();
        assert_eq!(latest.version, "0.1.12");
        assert_eq!(
            latest.download_url.as_deref(),
            Some("https://github.com/o/r/releases/download/desktop-v0.1.12/Sure-macOS-arm64.dmg")
        );
    }

    #[test]
    fn skips_releases_whose_dmg_is_not_attached_yet() {
        let releases = vec![
            release("desktop-v0.1.4", &["Sure-macOS-x86_64.dmg"]),
            release("desktop-v0.1.3", &["Sure-macOS-arm64.dmg"]),
        ];
        let latest = pick_latest(releases, Some("Sure-macOS-arm64.dmg")).unwrap();
        assert_eq!(latest.version, "0.1.3");
        assert!(pick_latest(vec![release("desktop-v0.1.5", &[])], Some("Sure-macOS-arm64.dmg")).is_none());
    }

    #[test]
    fn finds_the_update_manifest_next_to_the_dmg() {
        let releases = vec![release("desktop-v0.1.4", &["Sure-macOS-arm64.dmg", "latest.json"])];
        let latest = pick_latest(releases, Some("Sure-macOS-arm64.dmg")).unwrap();
        assert_eq!(
            latest.manifest_url.as_deref(),
            Some("https://github.com/o/r/releases/download/desktop-v0.1.4/latest.json")
        );
        let without = pick_latest(vec![release("desktop-v0.1.4", &["Sure-macOS-arm64.dmg"])], Some("Sure-macOS-arm64.dmg")).unwrap();
        assert!(without.manifest_url.is_none());
        let elsewhere = pick_latest(vec![release("desktop-v0.1.4", &["latest.json"])], None).unwrap();
        assert!(elsewhere.manifest_url.is_none());
    }

    #[test]
    fn offers_release_page_where_no_dmg_is_built() {
        let latest = pick_latest(vec![release("desktop-v0.1.3", &[])], None).unwrap();
        assert!(latest.download_url.is_none());
        assert!(latest.release_url.starts_with("https://github.com/"));
    }
}
