//! Tauri glue for local AI: the Preferences window's commands, and applying a
//! change to the running Sure (restart Puma when its AI environment changes).

use crate::local_ai::{AiView, LocalAi};
use crate::local_backend::LocalBackend;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

const STATE_EVENT: &str = "local-ai-state";

/// Set once local mode starts; empty in builds without a bundled runtime.
#[derive(Default)]
pub struct AiHandle(pub Mutex<Option<Arc<LocalAi>>>);

impl AiHandle {
    fn get(&self) -> Result<Arc<LocalAi>, String> {
        self.0.lock().unwrap().clone().ok_or_else(|| "Local AI is only available when Sure runs on this computer.".into())
    }
}

/// Create the local AI manager for a starting local backend and point Sure at
/// it. Errors are logged, not fatal: Sure runs fine without local AI.
pub fn init(app: &AppHandle, ai: Option<LocalAi>) {
    let Some(ai) = ai.map(Arc::new) else { return };
    {
        let app = app.clone();
        ai.on_change(move |view| {
            let _ = app.emit(STATE_EVENT, view.clone());
        });
    }
    app.state::<LocalBackend>().set_extra_env(ai.rails_env());
    *app.state::<AiHandle>().0.lock().unwrap() = Some(ai);
}

/// The local_ai_* commands, as ACL permissions (see build.rs).
pub const COMMAND_PERMISSIONS: &[&str] = &[
    "allow-local-ai-state",
    "allow-local-ai-download",
    "allow-local-ai-cancel-download",
    "allow-local-ai-dismiss-error",
    "allow-local-ai-select",
    "allow-local-ai-set-enabled",
    "allow-local-ai-set-context",
    "allow-local-ai-delete",
    "allow-local-ai-add-custom",
];

/// Let Sure's Settings → Local AI page, served by the local backend at
/// `origin`, call the local AI commands. Remote Sure servers never get this.
pub fn grant_capability(app: &AppHandle, origin: &str) {
    let mut capability = tauri::ipc::CapabilityBuilder::new("local-sure-ai")
        .window("main")
        .remote(format!("{origin}/**"));
    for permission in COMMAND_PERMISSIONS {
        capability = capability.permission(*permission);
    }
    if let Err(e) = app.add_capability(capability) {
        eprintln!("[sure] failed to grant local AI commands to {origin}: {e}");
    }
}

/// Start llama-server once Sure is up, if local AI is on.
pub fn start_server(app: &AppHandle) {
    if let Ok(ai) = app.state::<AiHandle>().get() {
        ai.sync_server();
    }
}

pub fn stop(app: &AppHandle) {
    if let Ok(ai) = app.state::<AiHandle>().get() {
        ai.stop();
    }
}

/// Sure reads its AI settings from the environment at boot, so when what it
/// runs with differs from the settings, restart Puma (a few seconds) and
/// reload the main window.
fn apply(app: &AppHandle, ai: &Arc<LocalAi>) {
    let backend = app.state::<LocalBackend>();
    let wanted = ai.rails_env();
    if backend.extra_env() == wanted {
        return;
    }
    backend.set_extra_env(wanted);
    let app = app.clone();
    std::thread::spawn(move || match app.state::<LocalBackend>().restart_web() {
        Ok(_) => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.eval("window.location.reload()");
            }
        }
        Err(e) => eprintln!("[sure] restarting Sure for AI settings failed: {e}"),
    });
}

#[tauri::command]
pub fn local_ai_state(handle: State<AiHandle>) -> Option<AiView> {
    handle.get().ok().map(|ai| ai.view())
}

#[tauri::command]
pub fn local_ai_download(id: String, app: AppHandle, handle: State<AiHandle>) -> Result<(), String> {
    let ai = handle.get()?;
    let app2 = app.clone();
    ai.download(&id, move |ai| {
        // A finished download can make local AI usable (first model, already on).
        ai.sync_server();
        apply(&app2, ai);
    })
}

#[tauri::command]
pub fn local_ai_cancel_download(handle: State<AiHandle>) -> Result<(), String> {
    handle.get()?.cancel_download();
    Ok(())
}

#[tauri::command]
pub fn local_ai_dismiss_error(handle: State<AiHandle>) -> Result<(), String> {
    handle.get()?.dismiss_download_error();
    Ok(())
}

#[tauri::command]
pub fn local_ai_select(id: String, app: AppHandle, handle: State<AiHandle>) -> Result<(), String> {
    let ai = handle.get()?;
    ai.select(&id)?;
    apply(&app, &ai);
    Ok(())
}

#[tauri::command]
pub fn local_ai_set_enabled(enabled: bool, app: AppHandle, handle: State<AiHandle>) -> Result<(), String> {
    let ai = handle.get()?;
    ai.set_enabled(enabled)?;
    apply(&app, &ai);
    Ok(())
}

#[tauri::command]
pub fn local_ai_set_context(context: u32, app: AppHandle, handle: State<AiHandle>) -> Result<(), String> {
    let ai = handle.get()?;
    ai.set_context(context)?;
    apply(&app, &ai);
    Ok(())
}

#[tauri::command]
pub fn local_ai_delete(id: String, app: AppHandle, handle: State<AiHandle>) -> Result<(), String> {
    let ai = handle.get()?;
    ai.delete(&id)?;
    apply(&app, &ai);
    Ok(())
}

#[tauri::command]
pub fn local_ai_add_custom(name: String, source: String, handle: State<AiHandle>) -> Result<String, String> {
    handle.get()?.add_custom(&name, &source)
}
