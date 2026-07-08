//! Application error types and response conversions.

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
};
use thiserror::Error;

/// Unified error type for the printer backend.
#[derive(Debug, Error)]
pub enum AppError {
    #[error("File not found: {0}")]
    FileNotFound(String),

    #[error("Job not found: {0}")]
    JobNotFound(String),

    #[error("Invalid location: {0}")]
    InvalidLocation(String),

    #[error("Upload error: {0}")]
    UploadError(String),

    #[error("Rate limit exceeded")]
    RateLimitExceeded,

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Internal error: {0}")]
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = match &self {
            AppError::FileNotFound(_) => StatusCode::NOT_FOUND,
            AppError::JobNotFound(_) => StatusCode::NOT_FOUND,
            AppError::InvalidLocation(_) => StatusCode::BAD_REQUEST,
            AppError::UploadError(_) => StatusCode::BAD_REQUEST,
            AppError::RateLimitExceeded => StatusCode::TOO_MANY_REQUESTS,
            AppError::IoError(_) => StatusCode::INTERNAL_SERVER_ERROR,
            AppError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };

        (status, self.to_string()).into_response()
    }
}
