use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const FRAME_START: [u8; 3] = [b'@', b'#', b'$'];
pub const FRAME_END: [u8; 3] = [b'\n', b'\r', b'\0'];
pub const MAX_FRAME_SIZE: usize = 1024;

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("Frame start marker not found")]
    NoStartMarker,
    #[error("Frame end marker not found")]
    NoEndMarker,
    #[error("Frame too large (max {MAX_FRAME_SIZE} bytes)")]
    FrameTooLarge,
    #[error("Postcard deserialization error: {0}")]
    DeserializeError(#[from] postcard::Error),
    #[error("UTF-8 conversion error: {0}")]
    Utf8Error(#[from] std::string::FromUtf8Error),
}
#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
pub struct ImuData {
    pub accx: f32,
    pub accy: f32,
    pub accz: f32,
    pub temper: f32,
    pub angx: f32,
    pub angy: f32,
    pub angz: f32,
    pub angz_last: f32,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum MotorMessage {
    MotorInfo {
        motor_0_velocity: i32,
        motor_1_velocity: i32,
        motor_0_position: i32,
        motor_1_position: i32,
        imu_data: ImuData,
    },
    TextMsg {
        msg: String,
    },
    SystemHello,
    SystemReady,
    Error {
        msg: String,
    },
}

#[derive(Debug, Serialize, Deserialize)]
pub enum MotorCtrl {
    MotorAll(SingleMotorCtrl),
    Motor0(SingleMotorCtrl),
    Motor1(SingleMotorCtrl),
    Heartbeat,
}
#[derive(Debug, Serialize, Deserialize)]
pub enum SingleMotorCtrl {
    Stop,
    ConfigureProfileVelocityMode {
        acceleration: u32,
        deceleration: u32,
    },
    ConfigureProfilePositionMode {
        velocity: u32,
        acceleration: u32,
        deceleration: u32,
    },
    SetTargetVelocity {
        velocity: i32,
    },
    MoveAbsolute {
        target_position: i32,
    },
    MoveRelative {
        delta_position: i32,
    },
    HardWareInit,
}

impl MotorMessage {
    /// Parse raw bytes into a MotorMessage
    pub fn parse_from_bytes(data: &[u8]) -> Result<Self, ParseError> {
        // Check for frame size
        if data.len() > MAX_FRAME_SIZE {
            return Err(ParseError::FrameTooLarge);
        }

        // Check for frame start marker
        if data.len() < FRAME_START.len() || &data[..FRAME_START.len()] != FRAME_START {
            return Err(ParseError::NoStartMarker);
        }

        // Check for frame end marker
        if data.len() < FRAME_END.len() || &data[data.len() - FRAME_END.len()..] != FRAME_END {
            return Err(ParseError::NoEndMarker);
        }

        // Extract payload (between start and end markers)
        let payload_start = FRAME_START.len();
        let payload_end = data.len() - FRAME_END.len();

        if payload_end <= payload_start {
            return Err(ParseError::NoEndMarker);
        }

        let payload = &data[payload_start..payload_end];

        // Deserialize using postcard
        let message: MotorMessage = postcard::from_bytes(payload)?;
        Ok(message)
    }

    /// Serialize MotorMessage to bytes with frame markers
    pub fn to_bytes(&self) -> Result<Vec<u8>, postcard::Error> {
        let mut result = Vec::with_capacity(MAX_FRAME_SIZE);

        // Add frame start marker
        result.extend_from_slice(&FRAME_START);

        // Serialize message
        let serialized = postcard::to_allocvec(self)?;
        result.extend_from_slice(&serialized);

        // Add frame end marker
        result.extend_from_slice(&FRAME_END);

        Ok(result)
    }
}

impl MotorCtrl {
    /// Serialize MotorCtrl to bytes with frame markers
    pub fn to_bytes(&self) -> Result<Vec<u8>, postcard::Error> {
        let mut result = Vec::with_capacity(MAX_FRAME_SIZE);

        // Add frame start marker
        result.extend_from_slice(&FRAME_START);

        // Serialize command
        let serialized = postcard::to_allocvec(self)?;
        result.extend_from_slice(&serialized);

        // Add frame end marker
        result.extend_from_slice(&FRAME_END);

        Ok(result)
    }
}

/// Frame parser using Aho-Corasick algorithm for efficient pattern matching
pub struct FrameParser {
    ac: AhoCorasick,
    buffer: Vec<u8>,
    buffer_pos: usize,
}

impl FrameParser {
    /// Create a new FrameParser with the given frame markers
    pub fn new(frame_start: &[u8], frame_end: &[u8]) -> Self {
        // Build patterns for both start and end markers
        let patterns = vec![frame_start, frame_end];

        // Build Aho-Corasick automaton with standard configuration
        let ac = AhoCorasickBuilder::new()
            .match_kind(MatchKind::Standard)
            .build(patterns)
            .expect("Failed to build Aho-Corasick automaton");

        FrameParser {
            ac,
            buffer: Vec::with_capacity(MAX_FRAME_SIZE * 2),
            buffer_pos: 0,
        }
    }

    /// Reset the parser state
    pub fn reset(&mut self) {
        self.buffer.clear();
        self.buffer_pos = 0;
    }

    /// Process incoming bytes and extract complete frames
    /// Returns a vector of parsed MotorMessages
    pub fn process_byte(&mut self, data: u8) -> Option<MotorMessage> {
        // Add new data to buffer
        self.buffer.push(data);
        let mut result = None;
        // Process buffer to find frames
        let mut search_start = self.buffer_pos;

        while search_start < self.buffer.len() {
            // Find matches in the remaining buffer
            let mut matches: Vec<(usize, usize, usize)> = Vec::new();

            for mat in self.ac.find_overlapping_iter(&self.buffer[search_start..]) {
                matches.push((mat.pattern().as_usize(), mat.start(), mat.end()));
            }

            if matches.is_empty() {
                // No more matches in current buffer
                break;
            }

            // Process matches to find complete frames
            let mut frame_start_idx = None;
            let mut last_match_end = 0;

            for (pattern_id, start, end) in &matches {
                let absolute_start = search_start + start;
                let absolute_end = search_start + end;
                last_match_end = *end;

                if *pattern_id == 0 {
                    // This is a frame start marker
                    frame_start_idx = Some(absolute_start);
                } else if *pattern_id == 1 {
                    // This is a frame end marker
                    if let Some(start_idx) = frame_start_idx {
                        if absolute_end > start_idx {
                            // We have a complete frame from start_idx to absolute_end
                            let frame_data = &self.buffer[start_idx..absolute_end];

                            // Parse the frame
                            result = MotorMessage::parse_from_bytes(frame_data).ok();

                            // Update buffer position to after this frame
                            self.buffer_pos = absolute_end;
                            search_start = absolute_end;
                            frame_start_idx = None;

                            // Continue processing from new position
                            break;
                        }
                    }
                }
            }

            // If we didn't find a complete frame, break
            if frame_start_idx.is_some() {
                // We have a start but no end yet, wait for more data
                break;
            }

            // Move search start past the last processed position
            search_start += last_match_end;
        }

        // Clean up processed data from buffer
        if self.buffer_pos > 0 {
            self.buffer.drain(0..self.buffer_pos);
            self.buffer_pos = 0;
        }

        // Prevent buffer from growing too large
        if self.buffer.len() > MAX_FRAME_SIZE * 4 {
            self.buffer.truncate(MAX_FRAME_SIZE * 2);
        }

        result
    }

    /// Get current buffer size
    pub fn buffer_size(&self) -> usize {
        self.buffer.len()
    }
}
