//! Location listing handler.

use crate::models::SharedState;
use axum::{extract::State, http::StatusCode};
/// GET /api/locations
pub async fn list_locations(State(state): State<SharedState>) -> Result<String, StatusCode> {
    let dests = serde_json::to_string(&*state.jobs.lock().await)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(dests)
}
