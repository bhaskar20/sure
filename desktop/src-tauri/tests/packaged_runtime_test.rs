//! End-to-end smoke test of a built runtime (desktop/runtime), using the same
//! launcher code as the app: first launch, sign-up, restart, sign-in.
//!
//! Skipped unless SURE_RUNTIME_DIR points at a runtime folder, because building
//! one takes minutes:
//!
//!   SURE_RUNTIME_DIR=$PWD/../runtime cargo test --test packaged_runtime_test -- --nocapture
use std::path::PathBuf;
use std::time::Duration;
use sure_desktop_lib::local_backend::{DataDir, LocalBackend, Runtime};

struct Client {
    base: String,
    agent: ureq::Agent,
    cookies: Vec<(String, String)>,
}

impl Client {
    fn new(base: &str) -> Self {
        let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(60)).redirects(0).build();
        Client { base: base.to_string(), agent, cookies: Vec::new() }
    }

    fn cookie_header(&self) -> String {
        self.cookies.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; ")
    }

    fn keep_cookies(&mut self, resp: &ureq::Response) {
        for header in resp.all("set-cookie") {
            let pair = header.split(';').next().unwrap_or_default();
            if let Some((k, v)) = pair.split_once('=') {
                self.cookies.retain(|(name, _)| name != k);
                self.cookies.push((k.to_string(), v.to_string()));
            }
        }
    }

    /// (status, body, location)
    fn get(&mut self, path: &str) -> (u16, String, Option<String>) {
        let resp = match self.agent.get(&format!("{}{path}", self.base)).set("Cookie", &self.cookie_header()).call() {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => panic!("GET {path}: {e}"),
        };
        self.keep_cookies(&resp);
        let status = resp.status();
        let location = resp.header("location").map(str::to_string);
        (status, resp.into_string().unwrap_or_default(), location)
    }

    fn post_form(&mut self, path: &str, page: &str, fields: &[(&str, &str)]) -> (u16, Option<String>) {
        let token = authenticity_token(page);
        let mut form: Vec<(&str, &str)> = vec![("authenticity_token", token.as_str())];
        form.extend_from_slice(fields);
        let resp = match self
            .agent
            .post(&format!("{}{path}", self.base))
            .set("Cookie", &self.cookie_header())
            .send_form(&form)
        {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => panic!("POST {path}: {e}"),
        };
        self.keep_cookies(&resp);
        (resp.status(), resp.header("location").map(str::to_string))
    }
}

fn authenticity_token(html: &str) -> String {
    let marker = "name=\"authenticity_token\" value=\"";
    let start = html.find(marker).expect("form has an authenticity token") + marker.len();
    let end = start + html[start..].find('"').unwrap();
    html[start..end].replace("&#x2F;", "/").replace("&amp;", "&")
}

/// Prints every service log if the test fails after it is created, so CI shows
/// the cause of an HTTP error, not just the status code.
struct DumpLogsOnFailure<'a>(&'a DataDir);

impl Drop for DumpLogsOnFailure<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            dump_logs(self.0);
        }
    }
}

/// Print every service log (and Valkey's generated config) after a failed boot.
fn dump_logs(data: &DataDir) {
    let mut files: Vec<PathBuf> = std::fs::read_dir(data.logs())
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    files.push(data.valkey().join("valkey.conf"));
    for f in files {
        let text = std::fs::read_to_string(&f).unwrap_or_else(|e| format!("<unreadable: {e}>"));
        eprintln!("----- {} (error lines) -----", f.display());
        let errors = text.lines().filter(|l| {
            !l.trim_start().starts_with("from ") && !l.contains(".rb:") && !l.contains("does not exist")
                && ["Error", "error:", "aborted", "FATAL", "ERROR", "No such", "Caused by", "PG::", "failed", "connection"]
                    .iter()
                    .any(|k| l.contains(k))
        });
        for line in errors.take(30) {
            eprintln!("{line}");
        }
        eprintln!("----- {} (last lines) -----", f.display());
        let tail: Vec<&str> = text.lines().rev().take(40).collect();
        for line in tail.into_iter().rev() {
            eprintln!("{line}");
        }
    }
}

fn port_of(url: &str) -> u16 {
    url.rsplit(':').next().unwrap().parse().unwrap()
}

#[test]
fn packaged_runtime_boots_signs_up_restarts_and_signs_in() {
    let Ok(runtime_dir) = std::env::var("SURE_RUNTIME_DIR") else {
        eprintln!("skipped: set SURE_RUNTIME_DIR to a built desktop runtime");
        return;
    };
    let rt = Runtime { root: PathBuf::from(runtime_dir) };
    assert!(rt.ruby().is_file(), "no bundled Ruby at {}", rt.ruby().display());

    let root = std::env::temp_dir().join(format!("sure-smoke-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let data = DataDir::new(root.clone());
    let _dump_on_failure = DumpLogsOnFailure(&data);
    let email = format!("smoke-{}@example.com", std::process::id());
    let password = format!("Smoke-{}-Aa1!", std::process::id());

    // First launch: fresh data folder, first-run sign-up.
    let backend = LocalBackend::default();
    let url = backend.boot(&rt, &data).unwrap_or_else(|e| {
        backend.stop();
        panic!("first boot failed: {e}");
    });
    assert!(backend.all_running());
    let mut web = Client::new(&url);
    let (status, page, _) = web.get("/registration/new");
    assert_eq!(status, 200, "first run shows sign-up");
    let (status, location) = web.post_form(
        "/registration",
        &page,
        &[("user[email]", &email), ("user[password]", &password), ("user[password_confirmation]", &password)],
    );
    assert_eq!(status, 302, "sign-up redirects");
    let (status, _, location2) = web.get("/");
    assert!(
        status == 302 && location2.as_deref().is_some_and(|l| l.ends_with("/onboarding")),
        "signed-in user lands on onboarding (sign-up -> {location:?}, / -> {status} {location2:?})"
    );
    backend.stop();
    assert!(sure_desktop_lib::local_backend::port_is_free(port_of(&url)), "web port released on stop");

    // Second launch on the same data: the account persists and can sign in.
    let backend = LocalBackend::default();
    let url = backend.boot(&rt, &data).unwrap_or_else(|e| {
        backend.stop();
        panic!("second boot failed: {e}");
    });
    let mut web = Client::new(&url);
    let (_, page, _) = web.get("/sessions/new");
    let (status, location) = web.post_form("/sessions", &page, &[("email", &email), ("password", &password)]);
    backend.stop();
    assert_eq!(status, 302, "sign-in redirects");
    assert!(
        location.as_deref().is_some_and(|l| !l.contains("/sessions")),
        "sign-in succeeds after restart (went to {location:?})"
    );

    let _ = std::fs::remove_dir_all(&root);
}
