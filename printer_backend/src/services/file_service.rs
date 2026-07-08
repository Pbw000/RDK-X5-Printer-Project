//! File upload handling and storage management.

use axum::extract::Multipart;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use crate::error::AppError;
use crate::models::{AppState, UploadedFile};

/// Process a multipart file upload, store the file on disk,
/// and register its metadata in the application state.
pub async fn handle_upload(
    state: &AppState,
    mut multipart: Multipart,
) -> Result<UploadedFile, AppError> {
    let max_bytes = state.app_config.max_upload_size_mb * 1024 * 1024;

    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::UploadError(e.to_string()))?
    {
        // We only process fields named "file".
        if !field.name().is_some_and(|n| n == "file") {
            continue;
        }
        let file_id = Uuid::new_v4();
        let stored_name = {
            let Some(file_name) = field.file_name() else {
                return Err(AppError::UploadError("No file name provided".into()));
            };
            let ext = std::path::Path::new(file_name)
                .extension()
                .and_then(|e| e.to_str())
                .map(|s| s.to_ascii_lowercase())
                .ok_or_else(|| AppError::UploadError("File has no extension".into()))?;
            let file_type = crate::models::FileType::from_extension(&ext)
                .ok_or_else(|| AppError::UploadError("Unsupported file extension".into()))?;
            if !file_type.is_printable() {
                return Err(AppError::UploadError("File type is not printable".into()));
            }
            format!("{}.{}", file_id, ext)
        };
        let stored_path = state.upload_dir.join(&stored_name);
        let mut file = tokio::fs::File::create(&stored_path).await?;
        let mut file_size: usize = 0;

        // Stream chunks directly to disk instead of buffering in memory
        while let Some(chunk) = field
            .chunk()
            .await
            .map_err(|e| AppError::UploadError(e.to_string()))?
        {
            file_size += chunk.len();
            if file_size > max_bytes {
                // Remove the over-sized file and abort.
                drop(file);
                let _ = tokio::fs::remove_file(&stored_path).await;
                return Err(AppError::UploadError(format!(
                    "File exceeds maximum upload size of {} MB",
                    state.app_config.max_upload_size_mb
                )));
            }
            file.write_all(&chunk).await?;
        }
        file.flush().await?;

        if file_size == 0 {
            return Err(AppError::UploadError("Empty file".into()));
        }

        let uploaded = UploadedFile {
            stored_name,
            file_size,
        };

        tracing::info!(
            file_id = %file_id,
            size = file_size,
            "File uploaded"
        );

        return Ok(uploaded);
    }

    Err(AppError::UploadError(
        "No file field found in the request".into(),
    ))
}
