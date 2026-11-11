fn main() {
    let bridge = std::path::Path::new("../dist/bridge.js");
    if !bridge.exists() {
        if let Some(parent) = bridge.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(bridge, "/* bridge placeholder */");
    }
    // Declaring the app's commands turns on Tauri's ACL for them: each needs an
    // explicit `allow-*` permission. The app's own windows get all of them
    // (capabilities/default.json); the local Sure server's origin is granted
    // only the local_ai_* ones at runtime (local_ai_app::grant_capability), and
    // remote Sure servers none.
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "list_servers",
            "add_server",
            "remove_server",
            "check_server",
            "active_server",
            "set_active_server",
            "get_launch_at_login",
            "set_launch_at_login",
            "start_sso",
            "local_backend_status",
            "dev_accounts",
            "local_ai_state",
            "local_ai_download",
            "local_ai_cancel_download",
            "local_ai_dismiss_error",
            "local_ai_select",
            "local_ai_set_enabled",
            "local_ai_set_context",
            "local_ai_delete",
            "local_ai_add_custom",
        ]),
    ))
    .expect("failed to run tauri-build");
}
