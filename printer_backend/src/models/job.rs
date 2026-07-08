use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Detected file type, derived from the uploaded file's extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileType {
    Pdf,
    Jpeg,
    Png,
    Txt,
}

impl FileType {
    /// Resolve from a lowercase extension string.
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext {
            "pdf" => Some(Self::Pdf),
            "jpg" | "jpeg" => Some(Self::Jpeg),
            "png" => Some(Self::Png),
            "txt" => Some(Self::Txt),
            _ => None,
        }
    }

    /// Derive from a stored filename (e.g. "uuid.pdf").
    pub fn from_stored_name(name: &str) -> Option<Self> {
        let ext = std::path::Path::new(name)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());
        ext.as_deref().and_then(Self::from_extension)
    }

    /// Returns true for file types that can be uploaded and printed (Pdf, Jpeg, Png, Txt).
    pub fn is_printable(&self) -> bool {
        matches!(self, Self::Pdf | Self::Jpeg | Self::Png | Self::Txt)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Copy)]
pub enum Priority {
    Low,
    Medium,
    High,
    Critical,
}

impl Default for Priority {
    fn default() -> Self {
        Self::Medium
    }
}

/// Lifecycle state of an uploaded / queued file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileState {
    Pending,
    Printing,
    Transferring,
    WaitingForPickUp,
    Removed,
}

/// A single print job in the queue.
#[derive(Debug, Clone, Serialize)]
pub struct PrintJob {
    pub file_id: Uuid,
    pub stored_name: String,
    pub file_path: PathBuf,
    pub file_type: FileType,
    pub est_time_sec: usize,
    pub priority: Priority,
}

/// Task info submitted by the client.
#[derive(Debug, Clone, Deserialize)]
pub struct TaskInfo {
    pub stored_name: String,
    #[serde(default)]
    pub priority: Priority,
}

/// Request body for job submission.
#[derive(Debug, Clone, Deserialize)]
pub struct SubmitJobRequest {
    pub location_id: usize,
    pub tasks: Vec<TaskInfo>,
}

/// Response for a successfully submitted job.
#[derive(Debug, Clone, Serialize)]
pub struct JobResponse {
    pub stored_name: String,
    pub est_time_sec: usize,
}
