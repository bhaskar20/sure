use std::path::PathBuf;
use sure_desktop_lib::local_backend::{
    load_or_create_secrets, rails_env, valkey_conf, DataDir, Runtime,
};

fn temp_data(name: &str) -> DataDir {
    let root = std::env::temp_dir().join(format!("sure-local-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let data = DataDir::new(root);
    data.create_all().unwrap();
    data
}

#[test]
fn secrets_are_generated_once_and_reused() {
    let data = temp_data("secrets");
    let first = load_or_create_secrets(&data).unwrap();
    assert_eq!(first.secret_key_base.len(), 128);
    assert_ne!(first.db_password, first.valkey_password);
    let ports = [first.web_port, first.db_port, first.valkey_port];
    assert!(ports.iter().all(|p| *p != 0));
    assert_ne!(ports[0], ports[1]);
    assert_ne!(ports[1], ports[2]);

    let second = load_or_create_secrets(&data).unwrap();
    // Secrets sign sessions and encrypt data at rest: they must never change.
    assert_eq!(first.secret_key_base, second.secret_key_base);
    assert_eq!(first.db_password, second.db_password);
    // Free ports are kept, so the app keeps the same local origin.
    assert_eq!(first.web_port, second.web_port);
    assert_eq!(first.encryption_primary_key, second.encryption_primary_key);
}

#[test]
fn encryption_keys_are_generated_and_added_to_older_secrets_files() {
    let data = temp_data("encryption");
    // A secrets file written before encryption keys existed.
    std::fs::write(
        data.secrets(),
        r#"{"secret_key_base":"abc","db_password":"d","valkey_password":"v","web_port":0,"db_port":0,"valkey_port":0}"#,
    )
    .unwrap();
    let s = load_or_create_secrets(&data).unwrap();
    assert_eq!(s.secret_key_base, "abc");
    for key in [&s.encryption_primary_key, &s.encryption_deterministic_key, &s.encryption_key_derivation_salt] {
        assert_eq!(key.len(), 64);
    }
    assert_ne!(s.encryption_primary_key, s.encryption_deterministic_key);
    // Rows written before the keys existed must stay readable.
    assert!(s.support_unencrypted_data);
    let again = load_or_create_secrets(&data).unwrap();
    assert_eq!(s.encryption_primary_key, again.encryption_primary_key);
    assert!(again.support_unencrypted_data);
}

#[test]
fn fresh_installs_encrypt_everything() {
    let data = temp_data("fresh-encryption");
    let s = load_or_create_secrets(&data).unwrap();
    assert!(!s.support_unencrypted_data);
}

#[test]
fn busy_saved_port_moves_to_a_free_one() {
    let data = temp_data("ports");
    let first = load_or_create_secrets(&data).unwrap();
    let _hold = std::net::TcpListener::bind(("127.0.0.1", first.web_port)).unwrap();
    let second = load_or_create_secrets(&data).unwrap();
    assert_ne!(first.web_port, second.web_port);
    assert_eq!(first.secret_key_base, second.secret_key_base);
}

#[test]
fn valkey_listens_on_loopback_with_a_password_and_persists() {
    let data = temp_data("valkey");
    let secrets = load_or_create_secrets(&data).unwrap();
    let conf = valkey_conf(&data, &secrets);
    assert!(conf.contains("bind 127.0.0.1\n"));
    assert!(conf.contains(&format!("port {}\n", secrets.valkey_port)));
    assert!(conf.contains(&format!("requirepass {}\n", secrets.valkey_password)));
    assert!(conf.contains("appendonly yes\n"));
    assert!(conf.contains("maxmemory-policy noeviction\n"));
}

#[test]
fn rails_env_points_every_writable_path_at_the_data_folder() {
    let data = temp_data("env");
    let secrets = load_or_create_secrets(&data).unwrap();
    let rt = Runtime { root: PathBuf::from("/Applications/Sure.app/Contents/Resources/runtime") };
    let env: std::collections::HashMap<_, _> = rails_env(&rt, &data, &secrets).into_iter().collect();
    assert_eq!(env["RAILS_ENV"], "production");
    assert_eq!(env["SURE_DESKTOP"], "1");
    assert_eq!(env["SELF_HOSTED"], "true");
    assert_eq!(env["DB_HOST"], "127.0.0.1");
    assert_eq!(env["RAILS_FORCE_SSL"], "false");
    assert_eq!(env["SECRET_KEY_BASE"], secrets.secret_key_base);
    assert_eq!(env["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"], secrets.encryption_primary_key);
    assert_eq!(env["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"], secrets.encryption_key_derivation_salt);
    assert_eq!(
        env["REDIS_URL"],
        format!("redis://:{}@127.0.0.1:{}/0", secrets.valkey_password, secrets.valkey_port)
    );
    for key in ["ACTIVE_STORAGE_ROOT", "BOOTSNAP_CACHE_DIR", "PIDFILE", "TMPDIR"] {
        assert!(PathBuf::from(&env[key]).starts_with(&data.root), "{key} is outside the data folder");
    }
    assert!(PathBuf::from(&env["BUNDLE_GEMFILE"]).starts_with(rt.app()));
    #[cfg(target_os = "macos")]
    assert!(env["DYLD_FALLBACK_LIBRARY_PATH"].starts_with(&rt.libvips().display().to_string()));
    #[cfg(windows)]
    assert!(env["PATH"].contains(&rt.libvips().display().to_string()));
}
