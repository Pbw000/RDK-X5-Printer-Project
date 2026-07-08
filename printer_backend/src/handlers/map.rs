//! Map snapshot endpoint.

use axum::http::{StatusCode, header};
use axum::response::IntoResponse;

use crate::models::map_data::get_map_json;

/// `GET /api/map`
///
/// Returns the first received occupancy grid snapshot as JSON (including
/// `width`, `height`, `resolution`, and base64 `data`),
/// or `404 NOT FOUND` if no map has been received yet.
pub async fn get_map() -> Result<impl IntoResponse, StatusCode> {
    let json = get_map_json()?;
    Ok((
        [(header::CONTENT_TYPE, "application/json")],
        json,
    ))
}
