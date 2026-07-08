mod error;
mod handlers;
mod middleware;
mod models;
mod ros_nav;
mod scheduler;
mod services;
mod auth_server;
mod static_files;

use axum::{
    Router,
    routing::{get, post},
};
use models::{AppState, SharedState};
use ros_nav::RosNav;
use scheduler::{runner::PrinterExecutor, scheduler::Scheduler};
use std::sync::Arc;
use std::time::Duration;
use tower_http::cors::CorsLayer;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() {
    // ---- Tracing ----
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "printer_backend=debug,tower_http=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let exec_path = std::env::current_exe()
        .expect("Failed to get exec path")
        .parent()
        .expect("No parent found for exe")
        .to_path_buf();

    // ---- Upload directory ----
    let upload_dir = exec_path.join("uploads");
    tokio::fs::create_dir_all(&upload_dir)
        .await
        .expect("Failed to create upload directory");
    tracing::info!(path = %upload_dir.display(), "Upload directory ready");

    // ---- ROS 2 navigation ----
    let ros_nav = RosNav::init().expect("Failed to initialize ROS 2 navigation");
    tracing::info!("ROS 2 navigation node started");

    let state: SharedState = Arc::new(AppState::new(
        exec_path.join("config"),
        upload_dir,
        ros_nav.clone(),
    ));

    tracing::info!(
        port = state.app_config.port,
        bind_all = state.app_config.bind_all,
        printer_name = ?state.app_config.printer_name,
        "App config"
    );

    // ---- Periodic path-cache refresh (every 30 seconds) ----
    ros_nav::spawn_cache_refresh(ros_nav.clone(), state.clone(), Duration::from_secs(30));
    // ---- Continuous position broadcast to SSE clients (1 Hz) ----
    ros_nav::spawn_position_broadcast(
        ros_nav.clone(),
        state.channels.printer_info_channels.clone(),
    );

    // ---- Resolve printer ----
    let printer = if let Some(ref name) = state.app_config.printer_name {
        PrinterExecutor::new(name).or_else(|| {
            tracing::warn!("Configured printer '{}' not found, trying default", name);
            PrinterExecutor::default()
        })
    } else {
        PrinterExecutor::default()
    };

    // ---- Spawn background printer task ----
    if let Some(printer) = printer {
        let bg_state = state.clone();
        tokio::spawn(async move {
            let scheduler = Scheduler;
            tracing::info!(
                printer_name = printer.name(),
                "Background printer task started"
            );
            scheduler::background::printing_task(bg_state, printer, scheduler).await;
        });
    } else {
        tracing::warn!("No printer available — printing features disabled. Set 'printer_name' in config/app.json or configure a system default printer.");
    }

    // ---- Spawn auth server on port 3001 ----
    let auth_state = state.clone();
    tokio::spawn(async move {
        auth_server::start_auth_server(auth_state).await;
    });

    // ---- API routes ----
    let api = Router::new()
        .route("/health", get(handlers::health::health_check))
        .route("/upload", post(handlers::upload::upload_file))
        .route("/locations", get(handlers::location::list_locations))
        .route("/jobs", post(handlers::job::submit_jobs))
        .route("/files/{file_id}/status", get(handlers::file_status::get_file_status))
        .route("/navigation/status", get(handlers::navigation::get_navigation_status))
        .route("/events", get(handlers::sse::printer_events))
        .route("/printer/status", get(handlers::printer_status::get_status))
        .route(
            "/printer/position",
            get(handlers::printer_status::get_position),
        )
        .route("/map", get(handlers::map::get_map));

    // ---- Start ----
    let bind = state.app_config.bind_address();

    // ---- Body size limit (from config) ----
    let max_body = state.app_config.max_upload_size_mb * 1024 * 1024;

    // ---- App ----
    let app = Router::new()
        .nest("/api", api)
        .fallback(static_files::serve_static)
        .layer(CorsLayer::permissive())
        .layer(axum::extract::DefaultBodyLimit::max(max_body))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(&bind).await.unwrap();
    tracing::info!(address = bind.as_str(), "Printer backend started");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await
    .unwrap();
}
