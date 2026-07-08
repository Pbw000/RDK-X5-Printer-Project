//! Navigation status handler.

use std::ops::Deref;

use axum::{extract::State};
use crate::models::SharedState;

/// GET /api/navigation/status
pub async fn get_navigation_status(
    State(state): State<SharedState>,
) -> String {
    let json = serde_json::to_string(state.navigation_status.read().await.deref()).unwrap_or_else(|e| format!("{{\"error\": \"Failed to serialize navigation status: {}\"}}", e));
    json
}
