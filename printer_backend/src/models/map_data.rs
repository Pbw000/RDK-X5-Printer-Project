//! OccupancyGrid map snapshot — serializable for REST/SSE delivery.

use axum::http::StatusCode;
use r2r::nav_msgs::msg::OccupancyGrid;
use serde::Serialize;
use std::sync::OnceLock;

/// Global storage for the first received map snapshot (JSON-serialized).
static MAP_DATA: OnceLock<String> = OnceLock::new();

/// Store the JSON-serialized map snapshot. Only the first call takes effect.
pub fn store_map_json(json: String) {
    let _ = MAP_DATA.set(json);
}

/// Retrieve the stored map JSON as a `&'static str`.
pub fn get_map_json() -> Result<&'static str, StatusCode> {
    MAP_DATA
        .get()
        .map(|s| s.as_str())
        .ok_or(StatusCode::NOT_FOUND)
}

/// A snapshot of the latest `/map` OccupancyGrid, ready for JSON delivery.
///
/// The raw `i8` grid data is base64-encoded so it travels efficiently over
/// both the REST endpoint and the SSE stream.
#[derive(Debug, Clone, Serialize)]
pub struct MapSnapshot {
    pub width: u32,
    pub height: u32,
    /// Metres per pixel.
    pub resolution: f32,
    /// Map origin in the `map` frame.
    pub origin_x: f64,
    pub origin_y: f64,
    pub origin_theta: f64,
    /// Base64-encoded occupancy data.
    /// Each decoded byte is an `i8`: –1 = unknown, 0–100 = occupancy probability.
    pub data: String,
}

impl MapSnapshot {
    /// Convert a raw ROS `OccupancyGrid` message into a serializable snapshot.
    pub fn from_occupancy_grid(grid: &OccupancyGrid) -> Self {
        let q = &grid.info.origin.orientation;
        let siny_cosp = 2.0 * (q.w * q.z + q.x * q.y);
        let cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
        let theta = siny_cosp.atan2(cosy_cosp);

        // Re-interpret i8 data as u8 for base64 encoding (bit-preserving).
        let raw: &[u8] = unsafe {
            std::slice::from_raw_parts(grid.data.as_ptr() as *const u8, grid.data.len())
        };

        Self {
            width: grid.info.width,
            height: grid.info.height,
            resolution: grid.info.resolution,
            origin_x: grid.info.origin.position.x,
            origin_y: grid.info.origin.position.y,
            origin_theta: theta,
            data: base64_encode(&raw),
        }
    }
}

// ---------------------------------------------------------------------------
// Minimal inline base64 encoder — avoids an extra dependency.
// ---------------------------------------------------------------------------

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(data: &[u8]) -> String {
    let len = data.len();
    let out_len = (len + 2) / 3 * 4;
    let mut out = Vec::with_capacity(out_len);

    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(B64[((triple >> 18) & 0x3F) as usize]);
        out.push(B64[((triple >> 12) & 0x3F) as usize]);
        out.push(if chunk.len() > 1 { B64[((triple >> 6) & 0x3F) as usize] } else { b'=' });
        out.push(if chunk.len() > 2 { B64[(triple & 0x3F) as usize] } else { b'=' });
    }

    // SAFETY: we only ever push ASCII bytes.
    unsafe { String::from_utf8_unchecked(out) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base64_empty() {
        assert_eq!(base64_encode(b""), "");
    }

    #[test]
    fn test_base64_one_byte() {
        assert_eq!(base64_encode(b"M"), "TQ==");
    }

    #[test]
    fn test_base64_two_bytes() {
        assert_eq!(base64_encode(b"Ma"), "TWE=");
    }

    #[test]
    fn test_base64_three_bytes() {
        assert_eq!(base64_encode(b"Man"), "TWFu");
    }

    #[test]
    fn test_base64_rfc4648() {
        // RFC 4648 test vectors
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }
}
