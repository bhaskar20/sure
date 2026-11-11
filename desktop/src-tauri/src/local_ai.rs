//! Local AI: run an LLM on this computer with the bundled llama.cpp server.
//!
//! Models are GGUF files kept in `<app local data>/local/models/`. The user
//! picks one in Preferences (a curated catalog, or any GGUF by HTTPS URL or
//! file path), and while local AI is on, `llama-server` serves it on 127.0.0.1
//! with a generated API key. Sure talks to it through its OpenAI-compatible
//! provider (see [`LocalAi::rails_env`]), so chat and auto-categorization work
//! without sending anything off the machine.
//!
//! Switching models only restarts llama-server: Sure always asks for the
//! model alias [`MODEL_ALIAS`]. Turning local AI on or off, or changing the
//! context size, changes Sure's environment, so the caller restarts Puma.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The model name Sure is configured with; llama-server answers to it
/// whichever GGUF it has loaded.
pub const MODEL_ALIAS: &str = "sure-local";
/// Sure's assistant sends its system prompt and tool definitions with every
/// chat request (about 14K tokens), and a tool call's results push the next
/// request past 16K, so smaller contexts can't serve it.
pub const DEFAULT_CONTEXT: u32 = 32_768;
pub const MIN_CONTEXT: u32 = 32_768;
const MAX_CONTEXT: u32 = 131_072;

/// A model offered in Preferences, pinned to an exact file and checksum.
#[derive(Clone, Debug, Serialize)]
pub struct CatalogModel {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub url: &'static str,
    pub file: &'static str,
    pub size: u64,
    pub sha256: &'static str,
    pub license: &'static str,
    /// Rough memory the model needs while running, for the UI.
    pub ram_gb: u32,
    pub recommended: bool,
    /// Extra llama-server flags (e.g. turning off "thinking" on hybrid models,
    /// which only slows tool calls down).
    #[serde(skip)]
    pub server_args: &'static [&'static str],
}

pub const CATALOG: &[CatalogModel] = &[
    CatalogModel {
        id: "qwen3-4b-instruct-2507",
        name: "Qwen3 4B Instruct",
        description: "Best balance: reliable tool calls for chat and categorization.",
        url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        size: 2_497_281_120,
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        license: "Apache-2.0",
        ram_gb: 7,
        recommended: true,
        server_args: &[],
    },
    CatalogModel {
        id: "qwen3-1.7b",
        name: "Qwen3 1.7B",
        description: "Light and fast; good for categorization on older machines.",
        url: "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
        file: "Qwen3-1.7B-Q4_K_M.gguf",
        size: 1_282_439_264,
        sha256: "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5",
        license: "Apache-2.0",
        ram_gb: 5,
        recommended: false,
        server_args: &["--reasoning-budget", "0"],
    },
    CatalogModel {
        id: "llama-3.2-3b-instruct",
        name: "Llama 3.2 3B Instruct",
        description: "Meta's small instruct model.",
        url: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        size: 2_019_377_696,
        sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
        license: "Llama 3.2 Community License",
        ram_gb: 6,
        recommended: false,
        server_args: &[],
    },
    CatalogModel {
        id: "qwen3-8b",
        name: "Qwen3 8B",
        description: "Strongest answers; needs a machine with 16 GB of memory.",
        url: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
        file: "Qwen3-8B-Q4_K_M.gguf",
        size: 5_027_783_488,
        sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785",
        license: "Apache-2.0",
        ram_gb: 11,
        recommended: false,
        server_args: &["--reasoning-budget", "0"],
    },
];

/// A model the user added: a GGUF downloaded from a URL, or a file on disk.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CustomModel {
    pub id: String,
    pub name: String,
    /// `https://…` to download into the models folder, or an absolute path.
    pub source: String,
}

/// Persisted settings (`local/ai.json`).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AiConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub active: Option<String>,
    #[serde(default = "default_context")]
    pub context: u32,
    #[serde(default)]
    pub custom: Vec<CustomModel>,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub api_key: String,
}

fn default_context() -> u32 {
    DEFAULT_CONTEXT
}

impl Default for AiConfig {
    fn default() -> Self {
        AiConfig { enabled: false, active: None, context: DEFAULT_CONTEXT, custom: Vec::new(), port: 0, api_key: String::new() }
    }
}

/// One row of the model list in Preferences.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct ModelView {
    pub id: String,
    pub name: String,
    pub description: String,
    pub size: u64,
    pub license: String,
    pub ram_gb: u32,
    pub recommended: bool,
    pub custom: bool,
    pub downloaded: bool,
    pub active: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct DownloadView {
    pub id: String,
    pub received: u64,
    pub total: u64,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ServerState {
    Off,
    Starting,
    Running,
    Failed { message: String },
}

/// Everything the Preferences window shows.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct AiView {
    /// False when this build has no bundled llama-server.
    pub available: bool,
    pub enabled: bool,
    pub context: u32,
    pub models: Vec<ModelView>,
    pub download: Option<DownloadView>,
    pub server: ServerState,
    pub models_dir: String,
    pub log: String,
}

type Listener = Box<dyn Fn(&AiView) + Send + Sync>;

pub struct LocalAi {
    server_exe: Option<PathBuf>,
    data_root: PathBuf,
    config: Mutex<AiConfig>,
    download: Mutex<Option<DownloadView>>,
    cancel: Arc<AtomicBool>,
    server: Mutex<Option<Child>>,
    server_state: Mutex<ServerState>,
    listener: Mutex<Option<Listener>>,
}

impl LocalAi {
    /// `server_exe`: the bundled llama-server, if this build has one.
    /// `data_root`: the local data folder (`…/local`).
    pub fn new(server_exe: Option<PathBuf>, data_root: PathBuf) -> Result<Self, String> {
        let ai = LocalAi {
            server_exe: server_exe.filter(|p| p.is_file()),
            data_root,
            config: Mutex::new(AiConfig::default()),
            download: Mutex::new(None),
            cancel: Arc::new(AtomicBool::new(false)),
            server: Mutex::new(None),
            server_state: Mutex::new(ServerState::Off),
            listener: Mutex::new(None),
        };
        let mut config: AiConfig =
            fs::read_to_string(ai.config_path()).ok().and_then(|j| serde_json::from_str(&j).ok()).unwrap_or_default();
        if config.api_key.is_empty() {
            config.api_key = random_hex(24)?;
        }
        if config.port == 0 {
            config.port = crate::local_backend::free_port()?;
        }
        config.context = config.context.clamp(MIN_CONTEXT, MAX_CONTEXT);
        *ai.config.lock().unwrap() = config;
        ai.save()?;
        Ok(ai)
    }

    pub fn on_change(&self, listener: impl Fn(&AiView) + Send + Sync + 'static) {
        *self.listener.lock().unwrap() = Some(Box::new(listener));
    }

    fn changed(&self) {
        let view = self.view();
        if let Some(l) = self.listener.lock().unwrap().as_ref() {
            l(&view);
        }
    }

    pub fn models_dir(&self) -> PathBuf {
        self.data_root.join("models")
    }

    fn config_path(&self) -> PathBuf {
        self.data_root.join("ai.json")
    }

    fn log_path(&self) -> PathBuf {
        self.data_root.join("logs").join("llama.log")
    }

    fn save(&self) -> Result<(), String> {
        fs::create_dir_all(&self.data_root).map_err(|e| e.to_string())?;
        let json = serde_json::to_string_pretty(&*self.config.lock().unwrap()).map_err(|e| e.to_string())?;
        let tmp = self.config_path().with_extension("tmp");
        fs::write(&tmp, json).map_err(|e| e.to_string())?;
        fs::rename(&tmp, self.config_path()).map_err(|e| e.to_string())
    }

    pub fn config(&self) -> AiConfig {
        self.config.lock().unwrap().clone()
    }

    /// Where a model's GGUF lives (or will, once downloaded).
    pub fn model_path(&self, id: &str) -> Option<PathBuf> {
        if let Some(m) = CATALOG.iter().find(|m| m.id == id) {
            return Some(self.models_dir().join(m.file));
        }
        let config = self.config.lock().unwrap();
        let custom = config.custom.iter().find(|m| m.id == id)?;
        if is_url(&custom.source) {
            Some(self.models_dir().join(file_name_from_url(&custom.source)?))
        } else {
            Some(PathBuf::from(&custom.source))
        }
    }

    fn is_downloaded(&self, id: &str) -> bool {
        self.model_path(id).is_some_and(|p| p.is_file())
    }

    pub fn view(&self) -> AiView {
        let config = self.config();
        let mut models: Vec<ModelView> = CATALOG
            .iter()
            .map(|m| ModelView {
                id: m.id.into(),
                name: m.name.into(),
                description: m.description.into(),
                size: m.size,
                license: m.license.into(),
                ram_gb: m.ram_gb,
                recommended: m.recommended,
                custom: false,
                downloaded: self.is_downloaded(m.id),
                active: config.active.as_deref() == Some(m.id),
            })
            .collect();
        for c in &config.custom {
            let size = self.model_path(&c.id).and_then(|p| fs::metadata(p).ok()).map(|m| m.len()).unwrap_or(0);
            models.push(ModelView {
                id: c.id.clone(),
                name: c.name.clone(),
                description: c.source.clone(),
                size,
                license: String::new(),
                ram_gb: 0,
                recommended: false,
                custom: true,
                downloaded: self.is_downloaded(&c.id),
                active: config.active.as_deref() == Some(c.id.as_str()),
            });
        }
        AiView {
            available: self.server_exe.is_some(),
            enabled: config.enabled,
            context: config.context,
            models,
            download: self.download.lock().unwrap().clone(),
            server: self.server_state.lock().unwrap().clone(),
            models_dir: self.models_dir().display().to_string(),
            log: self.log_path().display().to_string(),
        }
    }

    /// Local AI is on and its model is on disk: Sure should use it.
    pub fn ready(&self) -> bool {
        let config = self.config();
        self.server_exe.is_some() && config.enabled && config.active.as_deref().is_some_and(|id| self.is_downloaded(id))
    }

    /// Variables that point Sure's OpenAI-compatible provider at llama-server,
    /// tuned for a local model per Sure's local-LLM guidance. Empty when local
    /// AI is off, so a cloud provider configured in Sure's settings applies.
    pub fn rails_env(&self) -> Vec<(String, String)> {
        if !self.ready() {
            return Vec::new();
        }
        let config = self.config();
        [
            ("LLM_PROVIDER", "openai".to_string()),
            ("OPENAI_ACCESS_TOKEN", config.api_key.clone()),
            ("OPENAI_URI_BASE", format!("http://127.0.0.1:{}/v1", config.port)),
            ("OPENAI_MODEL", MODEL_ALIAS.to_string()),
            ("OPENAI_SUPPORTS_PDF_PROCESSING", "false".to_string()),
            ("LLM_CONTEXT_WINDOW", config.context.to_string()),
            ("OPENAI_REQUEST_TIMEOUT", "300".to_string()),
            ("ASSISTANT_MAX_TOOL_CALL_ITERATIONS", "3".to_string()),
            ("AI_RESPONSE_TIMEOUT", "1500".to_string()),
            ("RAILS_AI_MAX_THREADS", "1".to_string()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect()
    }

    /// llama-server's command line for the active model.
    pub fn server_args(&self, model: &Path) -> Vec<String> {
        let config = self.config();
        let mut args: Vec<String> = vec![
            "-m".into(),
            model.display().to_string(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            config.port.to_string(),
            "--api-key".into(),
            config.api_key.clone(),
            "--alias".into(),
            MODEL_ALIAS.into(),
            "--ctx-size".into(),
            config.context.to_string(),
            // Offload every layer to the GPU when there is one (Metal on Macs,
            // Vulkan on Windows); llama.cpp falls back to the CPU otherwise.
            "--n-gpu-layers".into(),
            "999".into(),
            "--parallel".into(),
            "1".into(),
            // 8-bit KV cache: about half the memory of the default for the
            // large contexts Sure needs, with negligible quality loss.
            "--cache-type-k".into(),
            "q8_0".into(),
            "--cache-type-v".into(),
            "q8_0".into(),
            "--flash-attn".into(),
            "on".into(),
            "--jinja".into(),
            "--no-webui".into(),
            "--offline".into(),
        ];
        if let Some(m) = config.active.as_deref().and_then(|id| CATALOG.iter().find(|m| m.id == id)) {
            args.extend(m.server_args.iter().map(|s| s.to_string()));
        }
        args
    }

    // -- Settings changes ----------------------------------------------------

    /// Turn local AI on or off. Returns true when Sure must restart to pick
    /// up the change.
    pub fn set_enabled(self: &Arc<Self>, enabled: bool) -> Result<bool, String> {
        let before = self.ready();
        self.config.lock().unwrap().enabled = enabled;
        self.save()?;
        self.sync_server();
        Ok(before != self.ready())
    }

    /// Use a model. Returns true when Sure must restart (it became usable).
    pub fn select(self: &Arc<Self>, id: &str) -> Result<bool, String> {
        if self.model_path(id).is_none() {
            return Err(format!("Unknown model {id}"));
        }
        let before = self.ready();
        self.config.lock().unwrap().active = Some(id.to_string());
        self.save()?;
        self.restart_server();
        Ok(before != self.ready())
    }

    /// Context window in tokens. Returns true when Sure must restart.
    pub fn set_context(self: &Arc<Self>, context: u32) -> Result<bool, String> {
        let context = context.clamp(MIN_CONTEXT, MAX_CONTEXT);
        self.config.lock().unwrap().context = context;
        self.save()?;
        self.restart_server();
        Ok(self.ready())
    }

    pub fn add_custom(&self, name: &str, source: &str) -> Result<String, String> {
        let name = name.trim();
        let source = source.trim();
        if name.is_empty() {
            return Err("Give the model a name.".into());
        }
        if is_url(source) {
            if !source.starts_with("https://") {
                return Err("Model URLs must use https://.".into());
            }
            if file_name_from_url(source).is_none() {
                return Err("The URL must point to a .gguf file.".into());
            }
        } else {
            let path = Path::new(source);
            if !path.is_absolute() || !path.is_file() {
                return Err("Enter an https:// URL or the full path of a .gguf file.".into());
            }
            check_gguf(path)?;
        }
        let id = format!("custom-{}", random_hex(4)?);
        self.config.lock().unwrap().custom.push(CustomModel { id: id.clone(), name: name.into(), source: source.into() });
        self.save()?;
        self.changed();
        Ok(id)
    }

    /// Remove a downloaded file (and a custom entry). Returns true when Sure
    /// must restart because the active model went away.
    pub fn delete(self: &Arc<Self>, id: &str) -> Result<bool, String> {
        let before = self.ready();
        let custom_path_source = {
            let config = self.config.lock().unwrap();
            config.custom.iter().find(|m| m.id == id).map(|m| !is_url(&m.source))
        };
        // Never delete a file the user pointed us at; only our own downloads.
        if custom_path_source != Some(true) {
            if let Some(path) = self.model_path(id) {
                if path.starts_with(self.models_dir()) {
                    let _ = fs::remove_file(path);
                }
            }
        }
        {
            let mut config = self.config.lock().unwrap();
            config.custom.retain(|m| m.id != id);
            if config.active.as_deref() == Some(id) {
                config.active = None;
            }
        }
        self.save()?;
        self.sync_server();
        Ok(before != self.ready())
    }

    // -- Downloads -----------------------------------------------------------

    /// Download a model on a background thread; progress arrives via the
    /// change listener. `on_done` runs on that thread when it succeeds.
    pub fn download(self: &Arc<Self>, id: &str, on_done: impl FnOnce(&Arc<LocalAi>) + Send + 'static) -> Result<(), String> {
        if self.download.lock().unwrap().as_ref().is_some_and(|d| d.error.is_none()) {
            return Err("Another download is in progress.".into());
        }
        let (url, file, size, sha256) = if let Some(m) = CATALOG.iter().find(|m| m.id == id) {
            (m.url.to_string(), m.file.to_string(), Some(m.size), Some(m.sha256.to_string()))
        } else {
            let config = self.config();
            let c = config.custom.iter().find(|m| m.id == id).ok_or("Unknown model")?;
            if !is_url(&c.source) {
                return Err("This model is a file on disk; there is nothing to download.".into());
            }
            (c.source.clone(), file_name_from_url(&c.source).ok_or("Bad model URL")?, None, None)
        };
        fs::create_dir_all(self.models_dir()).map_err(|e| e.to_string())?;
        *self.download.lock().unwrap() =
            Some(DownloadView { id: id.into(), received: 0, total: size.unwrap_or(0), error: None });
        self.cancel.store(false, Ordering::SeqCst);
        self.changed();

        let ai = Arc::clone(self);
        let id = id.to_string();
        std::thread::spawn(move || {
            let dest = ai.models_dir().join(&file);
            match ai.fetch(&url, &dest, size, sha256.as_deref()) {
                Ok(()) => {
                    *ai.download.lock().unwrap() = None;
                    // A first download becomes the active model.
                    if ai.config().active.is_none() {
                        ai.config.lock().unwrap().active = Some(id);
                        let _ = ai.save();
                    }
                    ai.changed();
                    on_done(&ai);
                }
                Err(message) => {
                    if let Some(d) = ai.download.lock().unwrap().as_mut() {
                        d.error = Some(message);
                    }
                    ai.changed();
                }
            }
        });
        Ok(())
    }

    pub fn cancel_download(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }

    pub fn dismiss_download_error(&self) {
        let mut d = self.download.lock().unwrap();
        if d.as_ref().is_some_and(|d| d.error.is_some()) {
            *d = None;
        }
        drop(d);
        self.changed();
    }

    fn fetch(&self, url: &str, dest: &Path, size: Option<u64>, sha256: Option<&str>) -> Result<(), String> {
        let part = dest.with_extension("gguf.part");
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(20))
            .timeout_read(Duration::from_secs(60))
            .build();
        let resp = agent.get(url).call().map_err(|e| format!("Download failed: {e}"))?;
        let total = size.or_else(|| resp.header("content-length").and_then(|v| v.parse().ok())).unwrap_or(0);
        if let Some(d) = self.download.lock().unwrap().as_mut() {
            d.total = total;
        }
        let mut reader = resp.into_reader();
        let mut out = File::create(&part).map_err(|e| format!("Could not write {}: {e}", part.display()))?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        let mut received: u64 = 0;
        let mut last_report = Instant::now();
        loop {
            if self.cancel.load(Ordering::SeqCst) {
                drop(out);
                let _ = fs::remove_file(&part);
                return Err("Download cancelled.".into());
            }
            let n = reader.read(&mut buf).map_err(|e| format!("Download interrupted: {e}"))?;
            if n == 0 {
                break;
            }
            out.write_all(&buf[..n]).map_err(|e| format!("Could not write the model: {e}"))?;
            hasher.update(&buf[..n]);
            received += n as u64;
            if last_report.elapsed() > Duration::from_millis(400) {
                if let Some(d) = self.download.lock().unwrap().as_mut() {
                    d.received = received;
                }
                self.changed();
                last_report = Instant::now();
            }
        }
        out.sync_all().map_err(|e| e.to_string())?;
        drop(out);
        let fail = |msg: String| {
            let _ = fs::remove_file(&part);
            Err(msg)
        };
        if let Some(expected) = size {
            if received != expected {
                return fail(format!("Download incomplete ({received} of {expected} bytes)."));
            }
        }
        if let Some(expected) = sha256 {
            let actual = hex(&hasher.finalize());
            if actual != expected {
                return fail("The downloaded file does not match its checksum.".into());
            }
        }
        if let Err(e) = check_gguf(&part) {
            return fail(e);
        }
        fs::rename(&part, dest).map_err(|e| e.to_string())
    }

    // -- llama-server --------------------------------------------------------

    /// Start or stop llama-server to match the settings.
    pub fn sync_server(self: &Arc<Self>) {
        if self.ready() {
            if self.server.lock().unwrap().is_none() {
                self.start_server();
                if self.server.lock().unwrap().is_some() {
                    // Loading a model takes seconds; report when it answers.
                    let ai = Arc::clone(self);
                    std::thread::spawn(move || {
                        let _ = ai.wait_until_ready(Duration::from_secs(300));
                    });
                }
            }
        } else {
            self.stop();
        }
        self.changed();
    }

    pub fn restart_server(self: &Arc<Self>) {
        self.stop();
        self.sync_server();
    }

    fn set_server_state(&self, state: ServerState) {
        *self.server_state.lock().unwrap() = state;
        self.changed();
    }

    fn start_server(&self) {
        let (Some(exe), Some(model)) =
            (self.server_exe.clone(), self.config().active.as_deref().and_then(|id| self.model_path(id)))
        else {
            return;
        };
        let _ = fs::create_dir_all(self.log_path().parent().unwrap());
        let log = match OpenOptions::new().create(true).append(true).open(self.log_path()) {
            Ok(f) => f,
            Err(e) => return self.set_server_state(ServerState::Failed { message: e.to_string() }),
        };
        let mut cmd = Command::new(&exe);
        cmd.args(self.server_args(&model))
            .stdin(Stdio::null())
            .stdout(log.try_clone().map(Stdio::from).unwrap_or(Stdio::null()))
            .stderr(Stdio::from(log));
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        match cmd.spawn() {
            Ok(child) => {
                *self.server.lock().unwrap() = Some(child);
                self.set_server_state(ServerState::Starting);
            }
            Err(e) => self.set_server_state(ServerState::Failed { message: format!("Could not start llama-server: {e}") }),
        }
    }

    /// Wait until the model is loaded and answering (or failed). Called on a
    /// background thread after a start.
    pub fn wait_until_ready(&self, timeout: Duration) -> Result<(), String> {
        let port = self.config().port;
        let start = Instant::now();
        while start.elapsed() < timeout {
            {
                let mut server = self.server.lock().unwrap();
                match server.as_mut().map(|c| c.try_wait()) {
                    None => return Err("llama-server is not running.".into()),
                    Some(Ok(Some(status))) => {
                        *server = None;
                        drop(server);
                        let message = format!("llama-server exited ({status}). See {}", self.log_path().display());
                        self.set_server_state(ServerState::Failed { message: message.clone() });
                        return Err(message);
                    }
                    _ => {}
                }
            }
            if health_ok(port) {
                self.set_server_state(ServerState::Running);
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        let message = format!("The model did not load within {}s.", timeout.as_secs());
        self.set_server_state(ServerState::Failed { message: message.clone() });
        Err(message)
    }

    pub fn stop(&self) {
        if let Some(mut child) = self.server.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *self.server_state.lock().unwrap() = ServerState::Off;
    }
}

fn health_ok(port: u16) -> bool {
    let addr: SocketAddr = ([127, 0, 0, 1], port).into();
    let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(300)) else {
        return false;
    };
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    if s.write_all(b"GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n").is_err() {
        return false;
    }
    let mut buf = [0u8; 32];
    let n = s.read(&mut buf).unwrap_or(0);
    // "HTTP/1.1 200" once loaded; 503 while the model is still loading.
    buf[..n].windows(4).any(|w| w == b" 200")
}

fn is_url(source: &str) -> bool {
    source.starts_with("https://") || source.starts_with("http://")
}

/// The `.gguf` file name at the end of a URL (query string ignored).
pub fn file_name_from_url(url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next()?;
    let name = path.rsplit('/').next()?;
    let ok = name.to_ascii_lowercase().ends_with(".gguf")
        && name.len() > 5
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c));
    ok.then(|| name.to_string())
}

/// GGUF files start with the magic bytes "GGUF".
pub fn check_gguf(path: &Path) -> Result<(), String> {
    let mut magic = [0u8; 4];
    File::open(path).and_then(|mut f| f.read_exact(&mut magic)).map_err(|e| format!("Could not read the model: {e}"))?;
    if &magic != b"GGUF" {
        return Err("That file is not a GGUF model.".into());
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn random_hex(bytes: usize) -> Result<String, String> {
    let mut buf = vec![0u8; bytes];
    getrandom::getrandom(&mut buf).map_err(|e| e.to_string())?;
    Ok(hex(&buf))
}
