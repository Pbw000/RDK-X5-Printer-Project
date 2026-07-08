//! Job submission business logic.

use crate::error::AppError;
use crate::models::{AppState, FileState, FileType, JobResponse, PrintJob, SubmitJobRequest};
use uuid::Uuid;

fn estimate_time(file_size: usize) -> usize {
    let base = 10;
    let size_factor = file_size / 102400; // ~1s per 100KB
    base + size_factor
}
pub async fn submit_tasks(
    state: &AppState,
    req: SubmitJobRequest,
) -> Result<Vec<JobResponse>, AppError> {
    // Resolve location coordinates
    let mut dests = state.jobs.lock().await;
    let job_dest = dests.destinations.get_mut(req.location_id).ok_or_else(|| {
        AppError::InvalidLocation(format!("location_id {} not found", req.location_id))
    })?;

    let mut responses = Vec::with_capacity(req.tasks.len());
    for task in req.tasks.into_iter() {
        // Resolve file path directly from stored_name
        let file_path = state
            .upload_dir
            .join(&task.stored_name)
            .canonicalize()
            .map_err(|e| {
                AppError::FileNotFound(format!(
                    "failed to canonicalize path '{}': {}",
                    task.stored_name, e
                ))
            })?;

        if !file_path.exists() || !file_path.starts_with(&state.upload_dir) {
            return Err(AppError::FileNotFound(format!(
                "file '{}' not found",
                task.stored_name
            )));
        }
        // Get file size for time estimation
        let metadata = tokio::fs::metadata(&file_path).await?;
        let file_size = metadata.len() as usize;
        let est_time = estimate_time(file_size);
        let file_type = FileType::from_stored_name(&task.stored_name)
            .ok_or_else(|| {
                AppError::InvalidLocation(format!(
                    "Unsupported file type for '{}'",
                    task.stored_name
                ))
            })?;

        let file_id = task
            .stored_name
            .split_once('.')
            .and_then(|(prefix, _)| Uuid::try_parse(prefix).ok())
            .unwrap_or_else(Uuid::new_v4);

        let job = PrintJob {
            file_id,
            stored_name: task.stored_name.clone(),
            file_path,
            file_type,
            est_time_sec: est_time,
            priority: task.priority,
        };
        state.file_states.insert(file_id, FileState::Pending);
        tracing::info!(
            stored_name = %task.stored_name,
            location_id = req.location_id,
            "Job submitted"
        );
        responses.push(JobResponse {
            stored_name: task.stored_name,
            est_time_sec: est_time,
        });
        job_dest.pending_jobs.push(job);
    }

    // Wake the background printing task so it re-plans and starts printing.
    state.printer_state.notify_status_change();

    Ok(responses)
}
