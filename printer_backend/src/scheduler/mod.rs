pub mod background;
pub mod runner;
pub mod scheduler;

use serde::{Deserialize, Serialize};

use crate::models::location::PrintDestCord;

/// Real-time printer status events, broadcast via SSE.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub enum PrinterInfo<'a> {
    BatchStarted {
        location_id: usize,
        location_name: &'a str,
        total_jobs: usize,
    },
    PrintStarted {
        store_name: &'a str,
        location_id: usize,
        job_index: usize,
        total_jobs: usize,
    },
    PrintComplete {
        store_name: &'a str,
        location_id: usize,
    },
    PrintFailed {
        msg: &'a str,
        location_id: usize,
        store_name: &'a str,
    },
    BatchComplete {
        location_id: usize,
        location_name: &'a str,
        succeeded: usize,
        failed: usize,
    },
    ConfirmTick {
        remaining_secs: u64,
    },
    MovingTo {
        position: PrintDestCord,
        location_id: usize,
        location_name: &'a str,
    },
    MoveComplete {
        location_id: usize,
    },
    Idle,
    SchedulerError {
        msg: &'a str,
    },
    NavError {
        msg: &'a str,
        location_id: usize,
    },
}

/// Position update — ownable variant sent over the broadcast channel.
#[derive(Debug, Clone, Serialize)]
pub enum OwnedPrinterEvent {
    PositionUpdate {
        x: f64,
        y: f64,
        theta: f64,
    },
}
