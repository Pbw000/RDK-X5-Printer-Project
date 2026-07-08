//! Application configuration loaded from `config/app.json`.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Top-level application config.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Server listening port. Defaults to 3000.
    #[serde(default = "default_port")]
    pub port: u16,

    /// Explicit printer name to use. `None` means use the system default.
    #[serde(default)]
    pub printer_name: Option<String>,

    /// If `true`, bind to `0.0.0.0` (all interfaces).
    /// If `false`, bind to `127.0.0.1` (localhost only).
    /// Defaults to `true`.
    #[serde(default = "default_bind_all")]
    pub bind_all: bool,

    /// Maximum upload file size in megabytes. Defaults to 50 MB.
    #[serde(default = "default_max_upload_size_mb")]
    pub max_upload_size_mb: usize,
}

impl AppConfig {
    /// Load config from `config/app.json` relative to the given directory.
    /// Falls back to defaults if the file is missing or malformed.
    pub fn load_from_file(config_dir: &Path) -> Self {
        let config_path = config_dir.join("app.json");

        match std::fs::read_to_string(&config_path) {
            Ok(content) => match serde_json::from_str::<AppConfig>(&content) {
                Ok(config) => {
                    tracing::info!(path = %config_path.display(), "App config loaded");
                    config
                }
                Err(e) => {
                    tracing::warn!(
                        path = %config_path.display(),
                        error = %e,
                        "Failed to parse app.json, using defaults"
                    );
                    Self::default()
                }
            },
            Err(e) => {
                tracing::warn!(
                    path = %config_path.display(),
                    error = %e,
                    "app.json not found, using defaults"
                );
                Self::default()
            }
        }
    }

    /// Returns the bind address string, e.g. `"0.0.0.0:3000"` or `"127.0.0.1:3000"`.
    pub fn bind_address(&self) -> String {
        let host = if self.bind_all { "0.0.0.0" } else { "127.0.0.1" };
        format!("{}:{}", host, self.port)
    }
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            port: default_port(),
            printer_name: None,
            bind_all: default_bind_all(),
            max_upload_size_mb: default_max_upload_size_mb(),
        }
    }
}

fn default_port() -> u16 {
    3000
}

fn default_bind_all() -> bool {
    true
}

fn default_max_upload_size_mb() -> usize {
    50
}





