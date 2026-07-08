use axum::{
    Json,
    extract::State,
    response::{Html, IntoResponse},
    routing::{get, post},
    Router,
};
use serde::Serialize;
use std::sync::Arc;
use tracing::{info, warn};

use crate::models::AppState;

#[derive(Serialize)]
pub struct CompleteResponse {
    pub success: bool,
    pub message: String,
}

/// GET / — serve the confirmation front-end.
async fn serve_index() -> impl IntoResponse {
    Html(include_str!("../../static/auth.html"))
}

/// POST /api/complete — user confirms, notify the background task.
async fn complete(
    State(state): State<Arc<AppState>>,
) -> Json<CompleteResponse> {
    state.printer_state.notify_completion();
    info!("User confirmed completion, completer notified");
    Json(CompleteResponse {
        success: true,
        message: "已确认".into(),
    })
}

/// Build and start the confirmation server on port 3001.
pub async fn start_auth_server(state: Arc<AppState>) {
    let app = Router::new()
        .route("/", get(serve_index))
        .route("/api/complete", post(complete))
        .with_state(state);

    let bind = "0.0.0.0:3001";
    let listener = tokio::net::TcpListener::bind(bind)
        .await
        .expect("Failed to bind confirmation server on :3001");
    info!(address = bind, "Confirmation server started");
    if let Err(e) = axum::serve(listener, app).await {
        warn!(error = %e, "Confirmation server error");
    }
}
