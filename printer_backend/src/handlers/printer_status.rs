//! Printer status query endpoint.

use axum::{Json, extract::State};
use serde::Serialize;

use crate::models::SharedState;
use crate::models::printer_status::PrinterStatus;
use crate::ros_nav::Pose2D;

/// Detailed printer status response with queue info.
#[derive(Debug, Serialize)]
pub struct PrinterStatusResponse {
    pub status: PrinterStatus,
}

/// `GET /api/printer/status`
pub async fn get_status(State(state): State<SharedState>) -> Json<PrinterStatusResponse> {
    Json(PrinterStatusResponse {
        status: state.printer_state.get_status(),
    })
}

/// `GET /api/printer/position`
pub async fn get_position(State(state): State<SharedState>) -> Json<Pose2D> {
    Json(state.ros_nav.current_pose())
}
