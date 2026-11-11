//! Downloads a catalog model (the smallest, or SURE_TEST_MODEL) through the app's downloader and
//! serves it with the bundled llama-server: checksum verification, API-key
//! auth, and an OpenAI-style tool call like Sure's assistant makes.
//!
//! Needs a built runtime and a ~0.5 GB download, so it only runs on request:
//!
//!   SURE_RUNTIME_DIR=$PWD/../runtime SURE_TEST_LOCAL_AI=1 \
//!     cargo test --test local_ai_server_test -- --nocapture
//!
//! SURE_TEST_MODELS_DIR reuses a folder of already-downloaded models.
use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::time::Duration;
use sure_desktop_lib::local_ai::{LocalAi, CATALOG, MODEL_ALIAS};
use sure_desktop_lib::local_backend::Runtime;

#[test]
fn downloads_serves_and_answers_tool_calls() {
    let (Ok(runtime), Ok(_)) = (std::env::var("SURE_RUNTIME_DIR"), std::env::var("SURE_TEST_LOCAL_AI")) else {
        eprintln!("skipped: set SURE_RUNTIME_DIR and SURE_TEST_LOCAL_AI=1");
        return;
    };
    let rt = Runtime { root: PathBuf::from(runtime) };
    let root = std::env::var("SURE_TEST_MODELS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir().join(format!("sure-ai-e2e-{}", std::process::id())));
    std::fs::create_dir_all(&root).unwrap();
    let ai = Arc::new(LocalAi::new(Some(rt.llama_server()), root.clone()).unwrap());
    // SURE_TEST_MODEL picks a catalog model; the default is the smallest.
    let model = match std::env::var("SURE_TEST_MODEL") {
        Ok(id) => CATALOG.iter().find(|m| m.id == id).expect("SURE_TEST_MODEL is a catalog id"),
        Err(_) => CATALOG.iter().min_by_key(|m| m.size).unwrap(),
    };

    if !ai.view().models.iter().any(|m| m.id == model.id && m.downloaded) {
        let (tx, rx) = mpsc::channel();
        ai.download(model.id, move |_| tx.send(()).unwrap()).unwrap();
        if rx.recv_timeout(Duration::from_secs(1800)).is_err() {
            panic!("download failed: {:?}", ai.view().download);
        }
    }
    ai.select(model.id).unwrap();
    ai.set_enabled(true).unwrap(); // starts llama-server
    ai.wait_until_ready(Duration::from_secs(300)).unwrap_or_else(|e| {
        ai.stop();
        panic!("{e}");
    });

    let config = ai.config();
    let url = format!("http://127.0.0.1:{}/v1/chat/completions", config.port);
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(300)).build();
    let body = serde_json::json!({
        "model": MODEL_ALIAS,
        "messages": [
            {"role": "system", "content": "You are a finance assistant. Use the tools to answer."},
            {"role": "user", "content": "What are my account balances?"}
        ],
        "tools": [{
            "type": "function",
            "function": {
                "name": "get_accounts",
                "description": "List the user's accounts with their balances",
                "parameters": {"type": "object", "properties": {}, "required": []}
            }
        }],
        "temperature": 0
    });

    let unauthorized = agent.post(&url).send_json(body.clone());
    assert!(matches!(unauthorized, Err(ureq::Error::Status(401, _))), "requests need the API key");

    let resp: serde_json::Value = agent
        .post(&url)
        .set("Authorization", &format!("Bearer {}", config.api_key))
        .send_json(body)
        .unwrap_or_else(|e| {
            ai.stop();
            panic!("chat completion failed: {e}");
        })
        .into_json()
        .unwrap();
    ai.stop();

    let message = &resp["choices"][0]["message"];
    eprintln!("model reply: {message}");
    assert_eq!(resp["model"], MODEL_ALIAS);
    assert_eq!(message["tool_calls"][0]["function"]["name"], "get_accounts", "the model calls Sure's tool");

    if std::env::var("SURE_TEST_MODELS_DIR").is_err() {
        let _ = std::fs::remove_dir_all(&root);
    }
}
