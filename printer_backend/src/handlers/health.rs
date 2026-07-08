//! Health check endpoint.
/// `GET /api/health`
pub async fn health_check() -> &'static str {
    concat!(
        "{\"status\":\"ok\",\"service\":\"",
        env!("CARGO_PKG_NAME"),
        "\",\"version\":\"",
        env!("CARGO_PKG_VERSION"),
        "\"}"
    )
}
