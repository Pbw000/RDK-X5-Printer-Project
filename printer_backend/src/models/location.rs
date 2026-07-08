//! Print location model.

use serde::{Deserialize, Serialize};

use crate::models::PrintJob;

#[derive(Debug, Clone, Serialize, Deserialize, Copy)]
pub struct PrintDestCord {
    pub x_cord: f64,
    pub y_cord: f64,
}

/// A physical print location / printer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrintDestination {
    pub name: String,
    pub description: String,
    pub(crate) location: PrintDestCord,
    #[serde(skip)]
    pub pending_jobs: Vec<PrintJob>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrintDests {
    pub destinations: Vec<PrintDestination>,
}
impl PrintDests {
    pub fn load_from_json(json_str: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json_str)
    }
    pub fn load_from_file(
        file_path: &std::path::PathBuf,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let json_str = std::fs::read_to_string(file_path)?;
        Ok(serde_json::from_str(&json_str)?)
    }
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}
