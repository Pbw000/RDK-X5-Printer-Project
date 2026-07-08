//! Job submission handler.

use crate::error::AppError;
use crate::models::{JobResponse, SharedState, SubmitJobRequest};
use crate::services::job_service;
use axum::{Json, extract::State};
pub async fn submit_jobs(
    State(state): State<SharedState>,
    Json(req): Json<SubmitJobRequest>,
) -> Result<Json<Vec<JobResponse>>, AppError> {
    if req.tasks.is_empty() {
        return Err(AppError::UploadError("tasks list cannot be empty".into()));
    }

    let responses = job_service::submit_tasks(&state, req).await?;
    state.printer_state.notify_status_change();
    Ok(Json(responses))
}
