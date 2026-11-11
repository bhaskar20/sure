//! Local mode: run Sure entirely on this computer.
//!
//! A packaged build ships a `runtime/` resource folder with a relocatable Ruby,
//! the Rails app (gems vendored, assets precompiled), PostgreSQL and Valkey
//! (a Redis-compatible server). On launch we start all three, bound to
//! 127.0.0.1 only, with every byte of state under the app's local data folder:
//!
//! ```text
//! <app local data>/local/
//!   secrets.json    generated once: Rails secret, DB + Valkey passwords, ports
//!   pgdata/         PostgreSQL cluster
//!   valkey/         Valkey append-only file + config
//!   storage/        Active Storage uploads (attachments, statements, logos)
//!   cache/          bootsnap cache
//!   run/            pid files
//!   logs/           postgres.log, valkey.log, rails.log
//! ```
//!
//! Sidekiq runs embedded in the Puma process (see `config/puma.rb`), so there
//! are exactly three child processes. Builds without `runtime/` (plain
//! `tauri dev`) report [`Status::NotBundled`] and keep the remote-server flow.

use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

const DB_USER: &str = "sure";
const DB_NAME: &str = "sure_production";
const STATUS_EVENT: &str = "local-backend-status";

/// What the main window shows while the local server comes up.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Status {
    /// No bundled runtime: this build connects to a remote server instead.
    NotBundled,
    Starting { step: String },
    Ready { url: String },
    Failed { message: String, logs: String },
}

/// Secrets and ports, generated on first launch and reused afterwards. The
/// secrets must never change: they sign sessions and encrypt data at rest.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Secrets {
    pub secret_key_base: String,
    pub db_password: String,
    pub valkey_password: String,
    pub web_port: u16,
    pub db_port: u16,
    pub valkey_port: u16,
    /// Active Record encryption keys. Sure encrypts provider tokens, MFA
    /// secrets and other sensitive columns only when these are set explicitly,
    /// so they are generated here (and added to older secrets files).
    #[serde(default)]
    pub encryption_primary_key: String,
    #[serde(default)]
    pub encryption_deterministic_key: String,
    #[serde(default)]
    pub encryption_key_derivation_salt: String,
    /// Set when the keys were added to an install that already had data
    /// written unencrypted, so those rows stay readable (Rails' documented
    /// migration mode for turning encryption on).
    #[serde(default)]
    pub support_unencrypted_data: bool,
}

/// Where the bundled programs live.
#[derive(Clone, Debug)]
pub struct Runtime {
    pub root: PathBuf,
}

impl Runtime {
    pub fn locate(app: &AppHandle) -> Option<Runtime> {
        // Development builds (`tauri dev`) can use a runtime folder in place,
        // instead of Tauri copying ~700 MB of resources on every build.
        // Release builds always use their own bundled runtime.
        #[cfg(debug_assertions)]
        if let Some(dir) = std::env::var_os("SURE_RUNTIME_DIR") {
            let rt = Runtime { root: PathBuf::from(dir) };
            return rt.ruby().is_file().then_some(rt);
        }
        let root = app.path().resource_dir().ok()?.join("runtime");
        let rt = Runtime { root };
        rt.ruby().is_file().then_some(rt)
    }
    pub fn ruby(&self) -> PathBuf {
        self.root.join("ruby").join("bin").join(exe("ruby"))
    }
    pub fn pg(&self, name: &str) -> PathBuf {
        self.root.join("postgres").join("bin").join(exe(name))
    }
    pub fn valkey(&self) -> PathBuf {
        self.root.join("valkey").join(exe("valkey-server"))
    }
    pub fn app(&self) -> PathBuf {
        self.root.join("app")
    }
    /// llama.cpp's OpenAI-compatible server, for local AI models.
    pub fn llama_server(&self) -> PathBuf {
        self.root.join("llama").join(exe("llama-server"))
    }
    /// libvips for Active Storage image variants (avatars, logos, previews).
    pub fn libvips(&self) -> PathBuf {
        self.root.join("libvips")
    }
    pub fn ca_bundle(&self) -> PathBuf {
        self.root.join("ssl").join("cacert.pem")
    }
}

/// The data folder layout.
#[derive(Clone, Debug)]
pub struct DataDir {
    pub root: PathBuf,
}

impl DataDir {
    pub fn new(root: PathBuf) -> Self {
        DataDir { root }
    }
    pub fn pgdata(&self) -> PathBuf {
        self.root.join("pgdata")
    }
    pub fn valkey(&self) -> PathBuf {
        self.root.join("valkey")
    }
    pub fn storage(&self) -> PathBuf {
        self.root.join("storage")
    }
    pub fn cache(&self) -> PathBuf {
        self.root.join("cache")
    }
    pub fn run(&self) -> PathBuf {
        self.root.join("run")
    }
    pub fn logs(&self) -> PathBuf {
        self.root.join("logs")
    }
    pub fn secrets(&self) -> PathBuf {
        self.root.join("secrets.json")
    }
    pub fn create_all(&self) -> std::io::Result<()> {
        for d in [self.pgdata(), self.valkey(), self.storage(), self.cache(), self.run(), self.logs()] {
            fs::create_dir_all(d)?;
        }
        restrict_dir(&self.root);
        Ok(())
    }
}

type StatusListener = Box<dyn Fn(&Status) + Send + Sync>;

/// Supervises the local services. The Tauri app holds one as managed state;
/// tests drive one directly against a built runtime (no window needed).
#[derive(Default)]
pub struct LocalBackend {
    status: Mutex<Option<Status>>,
    children: Mutex<Vec<(&'static str, Child)>>,
    shutdown: Mutex<Option<ShutdownPlan>>,
    listener: Mutex<Option<StatusListener>>,
    /// PostgreSQL runs under pg_ctl (not as a child we hold): pg_ctl drops
    /// administrator rights on Windows, where postgres refuses to run elevated.
    postgres_started: Mutex<bool>,
    /// Extra variables for Sure's Ruby processes (local AI settings).
    extra_env: Mutex<Vec<(String, String)>>,
}

/// Everything needed to stop the services cleanly, captured at start.
#[derive(Clone)]
struct ShutdownPlan {
    runtime: Runtime,
    data: DataDir,
    secrets: Secrets,
}

static LOCAL_URL: Mutex<Option<String>> = Mutex::new(None);

/// The local server's base URL once it is up. Treated like a saved server for
/// popups, downloads and deep links.
pub fn local_url() -> Option<String> {
    LOCAL_URL.lock().unwrap().clone()
}

#[tauri::command]
pub fn local_backend_status(app: AppHandle) -> Status {
    app.state::<LocalBackend>().status()
}

/// Start the local services on a background thread when this build bundles them.
pub fn start(app: &AppHandle) {
    let backend = app.state::<LocalBackend>();
    {
        let app = app.clone();
        backend.on_status(move |status| {
            let _ = app.emit(STATUS_EVENT, status.clone());
        });
    }
    let Some(runtime) = Runtime::locate(app) else {
        backend.set_status(Status::NotBundled);
        return;
    };
    // Development builds keep separate data, so a `tauri dev` session never
    // stops (as stale) the services of an installed Sure that is running.
    let data_folder = if cfg!(debug_assertions) { "local-dev" } else { "local" };
    let data_root = match app.path().app_local_data_dir() {
        Ok(d) => d.join(data_folder),
        Err(e) => {
            backend.set_status(Status::Failed { message: e.to_string(), logs: String::new() });
            return;
        }
    };
    let data = DataDir::new(data_root);
    backend.set_status(Status::Starting { step: "Preparing".into() });
    let ai = crate::local_ai::LocalAi::new(Some(runtime.llama_server()), data.root.clone())
        .map_err(|e| eprintln!("[sure] local AI unavailable: {e}"))
        .ok();
    crate::local_ai_app::init(app, ai);
    let app = app.clone();
    std::thread::spawn(move || {
        let backend = app.state::<LocalBackend>();
        match backend.boot(&runtime, &data) {
            Ok(url) => {
                *LOCAL_URL.lock().unwrap() = Some(url.clone());
                crate::commands::grant_server_capability(&app, &url);
                backend.set_status(Status::Ready { url });
                crate::local_ai_app::start_server(&app);
            }
            Err(message) => {
                eprintln!("[sure] local backend failed: {message}");
                backend.stop();
                backend.set_status(Status::Failed { message, logs: data.logs().display().to_string() });
            }
        }
    });
}

/// Stop the local services with the app.
pub fn stop(app: &AppHandle) {
    crate::local_ai_app::stop(app);
    app.state::<LocalBackend>().stop();
}

impl LocalBackend {
    pub fn status(&self) -> Status {
        self.status.lock().unwrap().clone().unwrap_or(Status::NotBundled)
    }

    /// Called with every status change (the app forwards them to the window).
    pub fn on_status(&self, listener: impl Fn(&Status) + Send + Sync + 'static) {
        *self.listener.lock().unwrap() = Some(Box::new(listener));
    }

    fn set_status(&self, status: Status) {
        *self.status.lock().unwrap() = Some(status.clone());
        if let Some(listener) = self.listener.lock().unwrap().as_ref() {
            listener(&status);
        }
    }

    /// Start PostgreSQL, Valkey and Puma from `rt` with state in `data`, and
    /// return the local server's URL once it answers. On error the caller
    /// stops whatever already started.
    pub fn boot(&self, rt: &Runtime, data: &DataDir) -> Result<String, String> {
        data.create_all().map_err(|e| format!("Could not create {}: {e}", data.root.display()))?;
        // A previous run that crashed can leave services behind; stop ours first so
        // two servers never write the same data files, and so their ports free up
        // before we pick ports for this run.
        stop_stale(rt, data);
        let mut secrets = load_or_create_secrets(data)?;
        *self.shutdown.lock().unwrap() =
            Some(ShutdownPlan { runtime: rt.clone(), data: data.clone(), secrets: secrets.clone() });

        let step = |s: &str| self.set_status(Status::Starting { step: s.into() });

        step("Starting database");
        if !data.pgdata().join("PG_VERSION").is_file() {
            init_db(rt, data, &secrets)?;
        }
        let pg_log = data.logs().join("postgres.log");
        let options = format!(
            "-p {} -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c max_connections=40",
            secrets.db_port
        );
        let mut pg_ctl = Command::new(rt.pg("pg_ctl"));
        pg_ctl
            .args(["start", "-w", "-t", "60", "-D"])
            .arg(data.pgdata())
            .arg("-l")
            .arg(&pg_log)
            .args(["-o", &options]);
        let status = with_log(&mut pg_ctl, &data.logs().join("pg_ctl.log"))?
            .status()
            .map_err(|e| format!("Could not start PostgreSQL: {e}"))?;
        if !status.success() {
            return Err(format!("PostgreSQL did not start ({status}). {}", tail(&pg_log)));
        }
        *self.postgres_started.lock().unwrap() = true;
        self.wait_for_port("postgres", secrets.db_port, Duration::from_secs(30))?;

        step("Starting job queue");
        write_valkey_conf(data, &secrets)?;
        // Start in the data folder with a relative config path: Valkey makes the
        // config path absolute and only recognizes POSIX paths as absolute, so a
        // Windows path ("C:\...") would be resolved against the working folder.
        let vk = spawn_logged(
            Command::new(rt.valkey()).current_dir(data.valkey()).arg("valkey.conf"),
            &data.logs().join("valkey.log"),
        )?;
        self.remember("valkey", vk);
        self.wait_for_port("valkey", secrets.valkey_port, Duration::from_secs(30))?;

        step("Updating database");
        let rails_log = data.logs().join("rails.log");
        let extra = self.extra_env.lock().unwrap().clone();
        let mut prepare = rails_command(rt, data, &secrets, &extra, &rails_log)?;
        prepare.arg("bin/rails").arg("db:prepare");
        let status = prepare.status().map_err(|e| format!("Could not run Ruby: {e}"))?;
        if !status.success() {
            return Err(format!("Database setup failed ({status}). {}", tail(&rails_log)));
        }

        // Installs from before the app generated encryption keys hold plaintext in
        // encryptable columns: encrypt them once, then run with encryption only.
        if secrets.support_unencrypted_data {
            step("Encrypting existing data");
            let mut encrypt = rails_command(rt, data, &secrets, &extra, &rails_log)?;
            encrypt.arg("bin/rails").arg("desktop:encrypt_existing_data");
            let status = encrypt.status().map_err(|e| format!("Could not run Ruby: {e}"))?;
            if !status.success() {
                return Err(format!("Encrypting existing data failed ({status}). {}", tail(&rails_log)));
            }
            secrets.support_unencrypted_data = false;
            save_secrets(data, &secrets)?;
        }

        *self.shutdown.lock().unwrap() =
            Some(ShutdownPlan { runtime: rt.clone(), data: data.clone(), secrets: secrets.clone() });
        step("Starting Sure");
        self.start_web(rt, data, &secrets)
    }

    fn start_web(&self, rt: &Runtime, data: &DataDir, secrets: &Secrets) -> Result<String, String> {
        let extra = self.extra_env.lock().unwrap().clone();
        let mut web = rails_command(rt, data, secrets, &extra, &data.logs().join("rails.log"))?;
        web.args(["bin/desktop-puma", "-C", "config/puma.rb"]);
        let web = web.spawn().map_err(|e| format!("Could not start Sure: {e}"))?;
        self.remember("rails", web);

        let url = format!("http://127.0.0.1:{}", secrets.web_port);
        self.wait_for_http(&format!("{url}/up"), Duration::from_secs(180))?;
        Ok(url)
    }

    /// Extra environment for Sure's Ruby processes; applies to the next
    /// start (see [`LocalBackend::restart_web`]).
    pub fn set_extra_env(&self, env: Vec<(String, String)>) {
        *self.extra_env.lock().unwrap() = env;
    }

    pub fn extra_env(&self) -> Vec<(String, String)> {
        self.extra_env.lock().unwrap().clone()
    }

    /// Restart only Puma (with embedded Sidekiq), e.g. to apply new AI
    /// settings. The database and Valkey keep running.
    pub fn restart_web(&self) -> Result<String, String> {
        let plan = self.shutdown.lock().unwrap().clone().ok_or("Sure is not running.")?;
        let old = {
            let mut children = self.children.lock().unwrap();
            children.iter().position(|(n, _)| *n == "rails").map(|i| children.remove(i).1)
        };
        if let Some(mut child) = old {
            terminate(&mut child);
            if !wait_exit(&mut child, Duration::from_secs(20)) {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        self.start_web(&plan.runtime, &plan.data, &plan.secrets)
    }

    /// Stop all local services: web first, then the job queue, then the database.
    pub fn stop(&self) {
        let plan = self.shutdown.lock().unwrap().clone();
        let mut children = std::mem::take(&mut *self.children.lock().unwrap());
        // Reverse start order: rails, valkey, then the database.
        children.reverse();
        for (name, child) in children.iter_mut() {
            match (*name, &plan) {
                ("valkey", Some(p)) => {
                    let _ = valkey_shutdown(p.secrets.valkey_port, &p.secrets.valkey_password);
                }
                _ => terminate(child),
            }
            if !wait_exit(child, Duration::from_secs(15)) {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        let mut postgres_started = self.postgres_started.lock().unwrap();
        if let (true, Some(p)) = (*postgres_started, &plan) {
            let _ = pg_ctl_stop(&p.runtime, &p.data);
            *postgres_started = false;
        }
    }

    /// Whether every service started so far is still running.
    pub fn all_running(&self) -> bool {
        self.children.lock().unwrap().iter_mut().all(|(_, c)| matches!(c.try_wait(), Ok(None)))
    }

    fn remember(&self, name: &'static str, child: Child) {
        self.children.lock().unwrap().push((name, child));
    }

    fn wait_for_port(&self, name: &str, port: u16, timeout: Duration) -> Result<(), String> {
        let addr: SocketAddr = ([127, 0, 0, 1], port).into();
        let start = Instant::now();
        while start.elapsed() < timeout {
            if TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok() {
                return Ok(());
            }
            self.ensure_running(name)?;
            std::thread::sleep(Duration::from_millis(200));
        }
        Err(format!("{name} did not start within {}s.", timeout.as_secs()))
    }

    fn wait_for_http(&self, url: &str, timeout: Duration) -> Result<(), String> {
        let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).redirects(0).build();
        let start = Instant::now();
        while start.elapsed() < timeout {
            if let Ok(resp) = agent.get(url).call() {
                if resp.status() == 200 {
                    return Ok(());
                }
            }
            self.ensure_running("rails")?;
            std::thread::sleep(Duration::from_millis(500));
        }
        Err(format!("Sure did not respond within {}s.", timeout.as_secs()))
    }

    /// Fail fast when a service exited during startup instead of waiting out the timeout.
    fn ensure_running(&self, name: &str) -> Result<(), String> {
        let mut children = self.children.lock().unwrap();
        if let Some((_, child)) = children.iter_mut().find(|(n, _)| *n == name) {
            if let Ok(Some(status)) = child.try_wait() {
                let log = self.shutdown.lock().unwrap().as_ref().map(|p| p.data.logs().join(format!("{name}.log")));
                let detail = log.map(|l| tail(&l)).unwrap_or_default();
                return Err(format!("{name} exited during startup ({status}). {detail}"));
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Secrets and configuration

pub fn load_or_create_secrets(data: &DataDir) -> Result<Secrets, String> {
    let path = data.secrets();
    let existing: Option<Secrets> =
        fs::read_to_string(&path).ok().and_then(|j| serde_json::from_str(&j).ok());
    let existing_install = existing.is_some();
    let mut secrets = match existing {
        Some(s) => s,
        None => Secrets {
            secret_key_base: random_hex(64)?,
            db_password: random_hex(24)?,
            valkey_password: random_hex(24)?,
            web_port: 0,
            db_port: 0,
            valkey_port: 0,
            encryption_primary_key: String::new(),
            encryption_deterministic_key: String::new(),
            encryption_key_derivation_salt: String::new(),
            support_unencrypted_data: false,
        },
    };
    if existing_install && secrets.encryption_primary_key.is_empty() {
        secrets.support_unencrypted_data = true;
    }
    for key in [
        &mut secrets.encryption_primary_key,
        &mut secrets.encryption_deterministic_key,
        &mut secrets.encryption_key_derivation_salt,
    ] {
        if key.is_empty() {
            *key = random_hex(32)?;
        }
    }
    // Keep the same ports across launches when they are still free (stable
    // origin for the webview), and move to a free one otherwise.
    let mut taken = Vec::new();
    for port in [&mut secrets.web_port, &mut secrets.db_port, &mut secrets.valkey_port] {
        if *port == 0 || !port_is_free(*port) || taken.contains(port) {
            *port = free_port()?;
        }
        taken.push(*port);
    }
    save_secrets(data, &secrets)?;
    Ok(secrets)
}

fn save_secrets(data: &DataDir, secrets: &Secrets) -> Result<(), String> {
    let json = serde_json::to_string_pretty(secrets).map_err(|e| e.to_string())?;
    write_private(&data.secrets(), json.as_bytes())
}

fn init_db(rt: &Runtime, data: &DataDir, secrets: &Secrets) -> Result<(), String> {
    let pwfile = data.run().join("initdb.pw");
    write_private(&pwfile, secrets.db_password.as_bytes())?;
    // initdb refuses a non-empty target, so start from an empty folder.
    let _ = fs::remove_dir_all(data.pgdata());
    let log = data.logs().join("postgres.log");
    let status = with_log(
        Command::new(rt.pg("initdb"))
            .arg("-D")
            .arg(data.pgdata())
            .args(["-U", DB_USER, "-A", "scram-sha-256", "-E", "UTF8", "--no-locale"])
            .arg(format!("--pwfile={}", pwfile.display())),
        &log,
    )?
    .status()
    .map_err(|e| format!("Could not run initdb: {e}"));
    let _ = fs::remove_file(&pwfile);
    let status = status?;
    if !status.success() {
        return Err(format!("Database initialisation failed ({status}). {}", tail(&log)));
    }
    Ok(())
}

pub fn valkey_conf(data: &DataDir, secrets: &Secrets) -> String {
    // Quote paths: the data folder can contain spaces ("Application Support").
    let q = |p: &Path| format!("\"{}\"", p.display().to_string().replace('\\', "/"));
    format!(
        "bind 127.0.0.1\nprotected-mode yes\nport {port}\nrequirepass {pw}\ndir {dir}\n\
         pidfile {pid}\nappendonly yes\nappendfsync everysec\nsave \"\"\n\
         maxmemory-policy noeviction\ndaemonize no\n",
        port = secrets.valkey_port,
        pw = secrets.valkey_password,
        dir = q(&data.valkey()),
        pid = q(&data.run().join("valkey.pid")),
    )
}

fn write_valkey_conf(data: &DataDir, secrets: &Secrets) -> Result<PathBuf, String> {
    let path = data.valkey().join("valkey.conf");
    write_private(&path, valkey_conf(data, secrets).as_bytes())?;
    Ok(path)
}

/// Environment for every Ruby process. Mirrors what the Docker image sets, with
/// desktop overrides: loopback services, no TLS, and writable paths in `data`.
pub fn rails_env(rt: &Runtime, data: &DataDir, secrets: &Secrets) -> Vec<(String, String)> {
    let app = rt.app();
    let p = |path: PathBuf| path.display().to_string();
    let mut env = vec![
        ("RAILS_ENV", "production".to_string()),
        ("SURE_DESKTOP", "1".into()),
        ("SELF_HOSTED", "true".into()),
        ("SECRET_KEY_BASE", secrets.secret_key_base.clone()),
        ("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", secrets.encryption_primary_key.clone()),
        ("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY", secrets.encryption_deterministic_key.clone()),
        ("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", secrets.encryption_key_derivation_salt.clone()),
        (
            "ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA",
            secrets.support_unencrypted_data.to_string(),
        ),
        ("DB_HOST", "127.0.0.1".into()),
        ("DB_PORT", secrets.db_port.to_string()),
        ("POSTGRES_USER", DB_USER.into()),
        ("POSTGRES_PASSWORD", secrets.db_password.clone()),
        ("POSTGRES_DB", DB_NAME.into()),
        (
            "REDIS_URL",
            format!("redis://:{}@127.0.0.1:{}/0", secrets.valkey_password, secrets.valkey_port),
        ),
        ("RAILS_FORCE_SSL", "false".into()),
        ("RAILS_ASSUME_SSL", "false".into()),
        ("APP_DOMAIN", format!("127.0.0.1:{}", secrets.web_port)),
        ("PORT", secrets.web_port.to_string()),
        ("PIDFILE", p(data.run().join("puma.pid"))),
        ("RAILS_MAX_THREADS", "4".into()),
        ("DB_POOL", "10".into()),
        ("WEB_CONCURRENCY", "1".into()),
        ("ACTIVE_STORAGE_ROOT", p(data.storage())),
        ("BOOTSNAP_CACHE_DIR", p(data.cache().join("bootsnap"))),
        ("BUNDLE_GEMFILE", p(app.join("Gemfile"))),
        ("BUNDLE_PATH", p(app.join("vendor").join("bundle"))),
        ("BUNDLE_DEPLOYMENT", "1".into()),
        ("BUNDLE_WITHOUT", "development:test".into()),
        ("BUNDLE_APP_CONFIG", p(app.join(".bundle"))),
        ("RAILS_LOG_LEVEL", "info".into()),
        ("LANG", "en_US.UTF-8".into()),
        ("TMPDIR", p(data.run())),
    ];
    if rt.ca_bundle().is_file() {
        env.push(("SSL_CERT_FILE", p(rt.ca_bundle())));
    }
    let ruby_bin = rt.ruby().parent().map(Path::to_path_buf).unwrap_or_default();
    let sep = if cfg!(windows) { ";" } else { ":" };
    let path = std::env::var("PATH").unwrap_or_default();
    // ruby-vips dlopens libvips by name: Windows searches PATH for DLLs, macOS
    // the fallback library path (allowed by the runtime's entitlements).
    if cfg!(windows) {
        env.push(("PATH", format!("{}{sep}{}{sep}{path}", ruby_bin.display(), rt.libvips().display())));
    } else {
        env.push(("PATH", format!("{}{sep}{path}", ruby_bin.display())));
        env.push(("DYLD_FALLBACK_LIBRARY_PATH", format!("{}{sep}/usr/local/lib{sep}/usr/lib", rt.libvips().display())));
    }
    env.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

fn rails_command(
    rt: &Runtime,
    data: &DataDir,
    secrets: &Secrets,
    extra: &[(String, String)],
    log: &Path,
) -> Result<Command, String> {
    let mut cmd = Command::new(rt.ruby());
    cmd.current_dir(rt.app());
    for (k, v) in rails_env(rt, data, secrets).into_iter().chain(extra.iter().cloned()) {
        cmd.env(k, v);
    }
    // Never inherit a Ruby/Bundler setup from the user's shell.
    for k in ["RUBYOPT", "RUBYLIB", "GEM_HOME", "GEM_PATH", "BUNDLE_BIN_PATH"] {
        cmd.env_remove(k);
    }
    with_log(&mut cmd, log)?;
    Ok(cmd)
}

// ---------------------------------------------------------------------------
// Process helpers

fn exe(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

fn with_log<'a>(cmd: &'a mut Command, log: &Path) -> Result<&'a mut Command, String> {
    let out = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .map_err(|e| format!("Could not open {}: {e}", log.display()))?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    cmd.stdin(Stdio::null()).stdout(out).stderr(err);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    Ok(cmd)
}

fn spawn_logged(cmd: &mut Command, log: &Path) -> Result<Child, String> {
    let program = cmd.get_program().to_string_lossy().into_owned();
    with_log(cmd, log)?
        .spawn()
        .map_err(|e| format!("Could not start {program}: {e}"))
}

fn wait_exit(child: &mut Child, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Ok(Some(_)) = child.try_wait() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// Ask a process to exit gracefully (SIGTERM on Unix; no equivalent on Windows,
/// where the caller falls back to killing it).
fn terminate(child: &mut Child) {
    #[cfg(unix)]
    {
        let _ = Command::new("kill").args(["-TERM", &child.id().to_string()]).status();
    }
    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }
}

fn pg_ctl_stop(rt: &Runtime, data: &DataDir) -> std::io::Result<std::process::ExitStatus> {
    let mut cmd = Command::new(rt.pg("pg_ctl"));
    cmd.arg("stop").arg("-D").arg(data.pgdata()).args(["-m", "fast", "-w", "-t", "20"]);
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    cmd.status()
}

/// Send AUTH + SHUTDOWN over RESP, so the append-only file is flushed.
fn valkey_shutdown(port: u16, password: &str) -> std::io::Result<()> {
    let addr: SocketAddr = ([127, 0, 0, 1], port).into();
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(2))?;
    s.set_read_timeout(Some(Duration::from_secs(2)))?;
    let auth = format!("*2\r\n$4\r\nAUTH\r\n${}\r\n{}\r\n", password.len(), password);
    s.write_all(auth.as_bytes())?;
    let mut buf = [0u8; 64];
    let n = s.read(&mut buf)?;
    if !buf[..n].starts_with(b"+OK") {
        // Not our server (or wrong password): leave it alone.
        return Err(std::io::Error::other("valkey auth refused"));
    }
    s.write_all(b"*1\r\n$8\r\nSHUTDOWN\r\n")?;
    let _ = s.read(&mut buf);
    Ok(())
}

/// Stop services a crashed previous run left behind.
fn stop_stale(rt: &Runtime, data: &DataDir) {
    if data.pgdata().join("postmaster.pid").is_file() {
        let _ = pg_ctl_stop(rt, data);
    }
    // Only a server that accepts our password is ours.
    if let Ok(old) = fs::read_to_string(data.secrets()) {
        if let Ok(old) = serde_json::from_str::<Secrets>(&old) {
            let _ = valkey_shutdown(old.valkey_port, &old.valkey_password);
        }
    }
    let puma_pid = data.run().join("puma.pid");
    if let Ok(pid) = fs::read_to_string(&puma_pid) {
        let pid = pid.trim().to_string();
        if pid.chars().all(|c| c.is_ascii_digit()) && !pid.is_empty() {
            #[cfg(unix)]
            let _ = Command::new("kill").args(["-TERM", &pid]).status();
            #[cfg(windows)]
            let _ = Command::new("taskkill").args(["/PID", &pid, "/T", "/F"]).status();
            std::thread::sleep(Duration::from_millis(500));
        }
        let _ = fs::remove_file(&puma_pid);
    }
}

// ---------------------------------------------------------------------------
// Small utilities

pub fn port_is_free(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

pub fn free_port() -> Result<u16, String> {
    TcpListener::bind(("127.0.0.1", 0))
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .map_err(|e| format!("No free local port: {e}"))
}

fn random_hex(bytes: usize) -> Result<String, String> {
    let mut buf = vec![0u8; bytes];
    getrandom::getrandom(&mut buf).map_err(|e| e.to_string())?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

fn write_private(path: &Path, contents: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    {
        let mut opts = OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f: File = opts.open(&tmp).map_err(|e| format!("Could not write {}: {e}", tmp.display()))?;
        f.write_all(contents).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
    }
    fs::rename(&tmp, path).map_err(|e| format!("Could not write {}: {e}", path.display()))
}

fn restrict_dir(_dir: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(_dir, fs::Permissions::from_mode(0o700));
    }
}

/// Last lines of a log, to put in an error message.
fn tail(path: &Path) -> String {
    let text = fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = text.lines().rev().take(8).collect();
    lines.into_iter().rev().collect::<Vec<_>>().join("\n")
}
