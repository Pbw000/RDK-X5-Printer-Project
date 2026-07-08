//! Server-Sent Events (SSE) handler for real-time printer status.

use std::convert::Infallible;

use axum::extract::State;
use axum::response::sse::{Event, KeepAlive, Sse};
use futures_util::stream::Stream;
use tokio::sync::broadcast;

use crate::models::SharedState;
pub async fn printer_events(
    State(state): State<SharedState>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = state.channels.printer_info_channels.subscribe();
    let stream = futures::stream::unfold(rx, |mut rx| async move {
        match rx.recv().await {
            Ok(info) => {
                let event = Event::default().data(&*info);
                return Some((Ok(event), rx));
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                let event = Event::default()
                    .event("lagged")
                    .data(format!("{{\"skipped\":{}}}", n));
                return Some((Ok(event), rx));
            }
            Err(broadcast::error::RecvError::Closed) => {
                return None;
            }
        }
    });

    Sse::new(stream).keep_alive(KeepAlive::default())
}
