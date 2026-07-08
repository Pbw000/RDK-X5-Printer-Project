//! Shared application state.

use crate::models::app_config::AppConfig;
use crate::models::job::FileState;
use crate::models::location::PrintDests;
use crate::models::navigation_status::NavigationStatus;
use crate::models::printer_status::PrinterState;
use crate::ros_nav::RosNav;
use dashmap::DashMap;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::sync::broadcast::Sender;
use uuid::Uuid;
pub struct Channels {
    pub printer_info_channels: Sender<Arc<String>>,
}
/// Thread-safe shared application state.
pub type SharedState = Arc<AppState>;
pub struct AppState {
    pub channels: Channels,
    pub app_config: AppConfig,
    pub upload_dir: PathBuf,
    pub printer_state: PrinterState,
    pub jobs: tokio::sync::Mutex<PrintDests>,
    pub ros_nav: Arc<RosNav>,
    pub file_states: DashMap<Uuid, FileState>,
    pub navigation_status: RwLock<NavigationStatus>,
}

impl AppState {
    pub fn new(config_dir: PathBuf, upload_dir: PathBuf, ros_nav: Arc<RosNav>) -> Self {
        let config_path = config_dir.join("dest.json");
        let app_config = AppConfig::load_from_file(&config_dir);
        Self {
            app_config,
            channels: Channels {
                printer_info_channels: Sender::new(100),
            },
            printer_state: PrinterState::new(),
            upload_dir: upload_dir
                .canonicalize()
                .expect("Failed to canonicalize upload directory path"),
            jobs: tokio::sync::Mutex::new(
                PrintDests::load_from_file(&config_path)
                    .expect("Failed to load print destinations"),
            ),
            ros_nav,
            file_states: DashMap::new(),
            navigation_status: RwLock::new(NavigationStatus::empty()),
        }
    }
}

/// Metadata for a file that has been uploaded to the server.
#[derive(Debug, Clone, Serialize)]
pub struct UploadedFile {
    pub stored_name: String,
    pub file_size: usize,
}
