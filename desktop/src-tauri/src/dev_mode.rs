//! Development-only behaviour (debug builds, i.e. `tauri dev`). Release builds
//! never read any of these settings.
//!
//! Two modes, chosen by `scripts/dev-local.sh` through `SURE_DEV_MODE`:
//!
//! - **human** (`npm run dev:local`): the app runs on the default port
//!   (`SURE_WEB_PORT`, 3000) and, once Sure is up, the window lists the
//!   accounts in the dev data so you can sign in as one with a click. That
//!   sign-in is authorised by a random token made on each launch and passed
//!   only to this app's own Sure server.
//! - **agent** (`npm run dev:agent`): for coding agents. A separate port range
//!   and a separate data folder, so an agent never disturbs the human's app.

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DevMode {
    Human,
    Agent,
}

/// The dev mode, or None in release builds.
pub fn mode() -> Option<DevMode> {
    if !cfg!(debug_assertions) {
        return None;
    }
    Some(match std::env::var("SURE_DEV_MODE").as_deref() {
        Ok("agent") => DevMode::Agent,
        _ => DevMode::Human,
    })
}

/// The exact port the dev scripts reserved for Sure, if any.
pub fn forced_web_port() -> Option<u16> {
    mode()?;
    std::env::var("SURE_WEB_PORT").ok()?.parse().ok()
}

/// Suffix for the dev data folder: agents keep their data apart from the
/// human's, so the two can run from the same checkout.
pub fn data_folder_suffix() -> &'static str {
    match mode() {
        Some(DevMode::Agent) => "-agent",
        _ => "",
    }
}

static LOGIN_TOKEN: Mutex<Option<String>> = Mutex::new(None);

/// Make this launch's sign-in token (human mode only).
pub fn init_login_token() {
    if mode() != Some(DevMode::Human) {
        return;
    }
    let mut buf = [0u8; 24];
    if getrandom::getrandom(&mut buf).is_ok() {
        *LOGIN_TOKEN.lock().unwrap() = Some(buf.iter().map(|b| format!("{b:02x}")).collect());
    }
}

pub fn login_token() -> Option<String> {
    LOGIN_TOKEN.lock().unwrap().clone()
}

/// The variable that enables Sure's dev sign-in endpoints for this launch.
pub fn rails_env() -> Option<(String, String)> {
    login_token().map(|t| ("SURE_DESKTOP_DEV_LOGIN_TOKEN".to_string(), t))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DevAccount {
    pub email: String,
    pub name: String,
    pub role: String,
    pub family: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct DevSignIn {
    pub token: String,
    pub sign_in_url: String,
    pub accounts: Vec<DevAccount>,
}

/// The accounts the human can sign in as, read from the local Sure server.
#[tauri::command]
pub fn dev_accounts() -> Result<DevSignIn, String> {
    let token = login_token().ok_or("Account sign-in is only available in human dev mode.")?;
    let base = crate::local_backend::local_url().ok_or("Sure is not running yet.")?;
    let accounts = fetch_accounts(&base, &token)?;
    Ok(DevSignIn { token, sign_in_url: format!("{base}/desktop/dev_sign_in"), accounts })
}

/// The accounts on the Sure server at `base`, via its token-protected dev route.
pub fn fetch_accounts(base: &str, token: &str) -> Result<Vec<DevAccount>, String> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(10)).build();
    agent
        .get(&format!("{base}/desktop/dev_accounts"))
        .query("token", token)
        .call()
        .map_err(|e| format!("Could not list accounts: {e}"))?
        .into_json()
        .map_err(|e| format!("Could not read accounts: {e}"))
}
