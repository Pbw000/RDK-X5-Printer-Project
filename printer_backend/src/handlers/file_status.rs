//! File status handler.

use axum::{Json, extract::{Path, State}};
use uuid::Uuid;

use crate::error::AppError;
use crate::models::{FileState, SharedState, printer_status::PrinterStatus};

/// GET /api/files/:file_id/status
pub async fn get_file_status(
    State(state): State<SharedState>,
    Path(file_id): Path<Uuid>,
) -> Result<Json<FileState>, AppError> {
    let file_state = state
        .file_states
        .get(&file_id)
        .map(|entry| *entry)
        .unwrap_or(FileState::Removed);

    let resolved_state = if file_state == FileState::WaitingForPickUp
        && state.printer_state.get_status() != PrinterStatus::WaitingConfirmation
    {
        FileState::Transferring
    } else {
        file_state
    };

    Ok(Json(resolved_state))
}
