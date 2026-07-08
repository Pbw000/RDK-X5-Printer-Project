use std::sync::atomic::AtomicU64;

use serde::{Deserialize, Serialize};
use tokio::sync::Notify;

pub struct PrinterState {
    printer_waker: Notify,
    printer_completer: Notify,
    status: AtomicU64,
}
impl PrinterState {
    pub fn new() -> Self {
        Self {
            printer_waker: Notify::new(),
            printer_completer: Notify::new(),
            status: AtomicU64::new(0),
        }
    }

    pub fn get_status(&self) -> PrinterStatus {
        let value = self.status.load(std::sync::atomic::Ordering::Relaxed);
        PrinterStatus::from_u64(value)
    }

    pub fn set_status(&self, status: PrinterStatus) {
        let value = status.to_u64();
        self.status
            .store(value, std::sync::atomic::Ordering::Release);
    }
    pub fn notify_status_change(&self) {
        self.printer_waker.notify_waiters();
    }

    pub fn wait_for_status_change(&self) -> impl std::future::Future<Output = ()> + '_ {
        self.printer_waker.notified()
    }

    pub fn wait_for_completion(&self) -> impl std::future::Future<Output = ()> + '_ {
        self.printer_completer.notified()
    }

    pub fn notify_completion(&self) {
        self.printer_completer.notify_waiters();
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum PrinterStatus {
    Idle,
    Printing { total: u32, processed: u32 },
    Moving,
    WaitingConfirmation,
    Unknown,
    Error,
}

impl PrinterStatus {
    /// Tag is stored in the bottom 3 bits.
    ///   0b000 = Idle
    ///   0b001 = Printing  (bits 3..17 = total, bits 18+ = processed)
    ///   0b010 = Moving
    ///   0b011 = WaitingConfirmation
    ///   0b100 = Unknown
    ///   0b101 = Error
    fn from_u64(value: u64) -> Self {
        match value & 7 {
            0 => PrinterStatus::Idle,
            1 => PrinterStatus::Printing {
                total: ((value >> 3) & ((1 << 15) - 1)) as u32,
                processed: (value >> 18) as u32,
            },
            2 => PrinterStatus::Moving,
            3 => PrinterStatus::WaitingConfirmation,
            4 => PrinterStatus::Unknown,
            5 => PrinterStatus::Error,
            _ => PrinterStatus::Unknown,
        }
    }
    fn to_u64(&self) -> u64 {
        match self {
            PrinterStatus::Idle => 0,
            PrinterStatus::Printing { total, processed } => {
                let total_masked = (*total & ((1 << 15) - 1)) as u64;
                let processed_shifted = (*processed as u64) << 18;
                1 | (total_masked << 3) | processed_shifted
            }
            PrinterStatus::Moving => 2,
            PrinterStatus::WaitingConfirmation => 3,
            PrinterStatus::Unknown => 4,
            PrinterStatus::Error => 5,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_printer_status_serialization() {
        let status = PrinterStatus::Printing {
            total: 100,
            processed: 50,
        };
        let serialized = status.to_u64();
        let deserialized = PrinterStatus::from_u64(serialized);
        assert_eq!(status, deserialized);
    }

    #[test]
    fn test_printer_status_idle() {
        let status = PrinterStatus::Idle;
        let serialized = status.to_u64();
        let deserialized = PrinterStatus::from_u64(serialized);
        assert_eq!(status, deserialized);
    }

    #[test]
    fn test_printer_status_unknown() {
        let status = PrinterStatus::Unknown;
        let serialized = status.to_u64();
        let deserialized = PrinterStatus::from_u64(serialized);
        assert_eq!(status, deserialized);
    }

    #[test]
    fn test_printer_status_error() {
        let status = PrinterStatus::Error;
        let serialized = status.to_u64();
        let deserialized = PrinterStatus::from_u64(serialized);
        assert_eq!(status, deserialized);
    }

    #[test]
    fn test_printer_status_moving() {
        let status = PrinterStatus::Moving;
        let serialized = status.to_u64();
        let deserialized = PrinterStatus::from_u64(serialized);
        assert_eq!(status, deserialized);
    }
}
