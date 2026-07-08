//! File upload handler.

use crate::models::{SharedState, UploadedFile};
use crate::services::file_service;
use axum::{
    Json,
    extract::{Multipart, State},
};

/// POST /api/upload
pub async fn upload_file(
    State(state): State<SharedState>,
    multipart: Multipart,
) -> Result<Json<UploadedFile>, crate::error::AppError> {
    let uploaded = file_service::handle_upload(&state, multipart).await?;
    Ok(Json(uploaded))
}
