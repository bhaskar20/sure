use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use sure_desktop_lib::local_ai::{check_gguf, file_name_from_url, LocalAi, CATALOG, DEFAULT_CONTEXT, MODEL_ALIAS};

fn temp_root(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("sure-ai-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

/// A stand-in for the bundled llama-server: only its existence matters here.
fn fake_server(root: &Path) -> PathBuf {
    let exe = root.join("llama-server");
    std::fs::write(&exe, b"#!/bin/sh\n").unwrap();
    exe
}

fn fake_gguf(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, b"GGUF\x03\x00\x00\x00rest-of-model").unwrap();
}

#[test]
fn catalog_entries_are_pinned_https_gguf_files() {
    let mut ids = std::collections::HashSet::new();
    for m in CATALOG {
        assert!(ids.insert(m.id), "duplicate id {}", m.id);
        assert!(m.url.starts_with("https://huggingface.co/"), "{}", m.id);
        assert_eq!(file_name_from_url(m.url).as_deref(), Some(m.file), "{}", m.id);
        assert_eq!(m.sha256.len(), 64, "{}", m.id);
        assert!(m.sha256.chars().all(|c| c.is_ascii_hexdigit()), "{}", m.id);
        assert!(m.size > 100_000_000, "{}", m.id);
    }
    assert_eq!(CATALOG.iter().filter(|m| m.recommended).count(), 1);
}

#[test]
fn settings_persist_with_a_stable_port_and_key() {
    let root = temp_root("persist");
    let ai = Arc::new(LocalAi::new(Some(fake_server(&root)), root.clone()).unwrap());
    let first = ai.config();
    assert!(!first.enabled);
    assert_eq!(first.context, DEFAULT_CONTEXT);
    assert_eq!(first.api_key.len(), 48);
    assert_ne!(first.port, 0);
    ai.set_enabled(true).unwrap();
    ai.set_context(16384).unwrap();

    let again = LocalAi::new(Some(fake_server(&root)), root).unwrap().config();
    assert!(again.enabled);
    assert_eq!(again.context, 16384);
    assert_eq!(again.api_key, first.api_key);
    assert_eq!(again.port, first.port);
}

#[test]
fn context_is_clamped_to_a_usable_range() {
    let root = temp_root("clamp");
    let ai = Arc::new(LocalAi::new(Some(fake_server(&root)), root).unwrap());
    ai.set_context(10).unwrap();
    assert_eq!(ai.config().context, 2048);
    ai.set_context(10_000_000).unwrap();
    assert_eq!(ai.config().context, 131_072);
}

#[test]
fn sure_only_gets_ai_settings_when_enabled_with_a_downloaded_model() {
    let root = temp_root("env");
    let ai = Arc::new(LocalAi::new(Some(fake_server(&root)), root.clone()).unwrap());
    let model = &CATALOG[0];

    ai.set_enabled(true).unwrap();
    assert!(ai.rails_env().is_empty(), "no model chosen yet");
    ai.select(model.id).unwrap();
    assert!(ai.rails_env().is_empty(), "model not downloaded yet");

    fake_gguf(&ai.models_dir().join(model.file));
    assert!(ai.ready());
    let env: HashMap<_, _> = ai.rails_env().into_iter().collect();
    let config = ai.config();
    assert_eq!(env["LLM_PROVIDER"], "openai");
    assert_eq!(env["OPENAI_URI_BASE"], format!("http://127.0.0.1:{}/v1", config.port));
    assert_eq!(env["OPENAI_ACCESS_TOKEN"], config.api_key);
    assert_eq!(env["OPENAI_MODEL"], MODEL_ALIAS);
    assert_eq!(env["LLM_CONTEXT_WINDOW"], config.context.to_string());
    assert_eq!(env["RAILS_AI_MAX_THREADS"], "1");

    ai.set_enabled(false).unwrap();
    assert!(ai.rails_env().is_empty(), "off means Sure's own settings apply");
}

#[test]
fn builds_without_llama_server_never_enable_local_ai() {
    let root = temp_root("unavailable");
    let ai = Arc::new(LocalAi::new(None, root).unwrap());
    fake_gguf(&ai.models_dir().join(CATALOG[0].file));
    ai.select(CATALOG[0].id).unwrap();
    ai.set_enabled(true).unwrap();
    assert!(!ai.view().available);
    assert!(ai.rails_env().is_empty());
}

#[test]
fn server_listens_on_loopback_with_the_alias_key_and_model_flags() {
    let root = temp_root("args");
    let ai = Arc::new(LocalAi::new(Some(fake_server(&root)), root).unwrap());
    let thinking = CATALOG.iter().find(|m| m.id == "qwen3-1.7b").unwrap();
    ai.select(thinking.id).unwrap();
    let args = ai.server_args(Path::new("/models/m.gguf"));
    let joined = args.join(" ");
    let config = ai.config();
    assert!(joined.contains("-m /models/m.gguf"));
    assert!(joined.contains("--host 127.0.0.1"));
    assert!(joined.contains(&format!("--port {}", config.port)));
    assert!(joined.contains(&format!("--api-key {}", config.api_key)));
    assert!(joined.contains(&format!("--alias {MODEL_ALIAS}")));
    assert!(joined.contains("--no-webui"));
    assert!(joined.contains("--jinja"));
    assert!(joined.contains("--reasoning-budget 0"), "hybrid thinking models answer directly");
}

#[test]
fn custom_models_validate_their_source() {
    let root = temp_root("custom");
    let ai = Arc::new(LocalAi::new(Some(fake_server(&root)), root.clone()).unwrap());
    assert!(ai.add_custom("", "https://example.com/m.gguf").is_err(), "needs a name");
    assert!(ai.add_custom("x", "http://example.com/m.gguf").is_err(), "https only");
    assert!(ai.add_custom("x", "https://example.com/not-a-model.bin").is_err());
    assert!(ai.add_custom("x", "relative/path.gguf").is_err());
    let not_gguf = root.join("fake.gguf");
    std::fs::write(&not_gguf, b"nope").unwrap();
    assert!(ai.add_custom("x", not_gguf.to_str().unwrap()).is_err(), "checks the GGUF header");

    let url_id = ai.add_custom("From URL", "https://example.com/files/My-Model.Q4.gguf?download=true").unwrap();
    assert_eq!(ai.model_path(&url_id).unwrap(), ai.models_dir().join("My-Model.Q4.gguf"));

    let user_file = root.join("elsewhere").join("mine.gguf");
    fake_gguf(&user_file);
    let path_id = ai.add_custom("Mine", user_file.to_str().unwrap()).unwrap();
    assert_eq!(ai.model_path(&path_id).unwrap(), user_file);
    assert!(ai.view().models.iter().any(|m| m.id == path_id && m.downloaded && m.custom));

    // Deleting a model added by path forgets it but never deletes the user's file.
    ai.delete(&path_id).unwrap();
    assert!(user_file.is_file());
    assert!(!ai.view().models.iter().any(|m| m.id == path_id));
}

#[test]
fn deleting_the_active_download_turns_local_ai_off_for_sure() {
    let root = temp_root("delete");
    let ai = Arc::new(LocalAi::new(Some(fake_server(&root)), root).unwrap());
    let model = &CATALOG[0];
    let file = ai.models_dir().join(model.file);
    fake_gguf(&file);
    ai.select(model.id).unwrap();
    ai.set_enabled(true).unwrap();
    assert!(ai.ready());
    ai.delete(model.id).unwrap();
    assert!(!file.exists());
    assert_eq!(ai.config().active, None);
    assert!(ai.rails_env().is_empty());
}

#[test]
fn url_file_names_must_be_plain_gguf_names() {
    assert_eq!(file_name_from_url("https://h/a/b/Model-7B.Q4_K_M.gguf").as_deref(), Some("Model-7B.Q4_K_M.gguf"));
    assert_eq!(file_name_from_url("https://h/m.gguf?x=1#y").as_deref(), Some("m.gguf"));
    assert_eq!(file_name_from_url("https://h/m.bin"), None);
    assert_eq!(file_name_from_url("https://h/..%2F..%2Fevil.gguf"), None);
    assert_eq!(file_name_from_url("https://h/.gguf"), None);
}

#[test]
fn gguf_header_check() {
    let root = temp_root("magic");
    let good = root.join("a.gguf");
    fake_gguf(&good);
    assert!(check_gguf(&good).is_ok());
    let bad = root.join("b.gguf");
    std::fs::write(&bad, b"PK\x03\x04").unwrap();
    assert!(check_gguf(&bad).is_err());
}
