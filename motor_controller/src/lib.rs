//! ROS Resolver - A library for parsing and handling ROS motor messages
//!
//! This library provides functionality for parsing MotorMessage frames,
//! sending motor control commands, and handling background tasks for
//! serial communication.

pub mod explorer;
pub mod model;
pub mod ros_adoptor;
// Re-export commonly used types
pub use model::{FrameParser, MotorCtrl, MotorMessage, ParseError, SingleMotorCtrl};
