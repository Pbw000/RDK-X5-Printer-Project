//! Compile-time embedded static files using `rust-embed`.

use axum::{
    body::Body,
    http::{header, StatusCode, Uri},
    response::{IntoResponse, Response},
};
use rust_embed::RustEmbed;

/// Embed the entire `static/` directory into the binary at compile time.
#[derive(RustEmbed)]
#[folder = "static/"]
struct Assets;

/// Serve an embedded static file. Falls back to `index.html` for SPA routes.
pub async fn serve_static(uri: Uri) -> impl IntoResponse {
    let path = uri.path().trim_start_matches('/');

    // Try exact file first.
    if let Some(content) = Assets::get(path) {
        let mime = mime_guess::from_path(path).first_or_octet_stream();
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, mime.as_ref())
            .header(header::CACHE_CONTROL, "public, max-age=3600")
            .body(Body::from(content.data))
            .unwrap();
    }

    // SPA fallback: serve index.html for unknown paths.
    if let Some(index) = Assets::get("index.html") {
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
            .body(Body::from(index.data))
            .unwrap();
    }

    // Should never happen if static/index.html exists.
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .body(Body::empty())
        .unwrap()
}
