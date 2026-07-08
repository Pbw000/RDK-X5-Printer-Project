//! Autonomous exploration module - integrated into ros_resolver
//!
//! Architecture:
//!   process_task -> scan_tx -> Explorer (receives scan data)
//!   Explorer -> command_tx -> send_task (sends motor commands)
//!
//! Features:
//! - VFH (Vector Field Histogram) obstacle avoidance
//! - Coverage grid to prevent revisiting areas
//! - Heading memory to avoid circular patterns
//! - Stuck detection and recovery
//! - Frontier-based exploration bias

use std::f64::consts::PI;
use std::collections::HashSet;
use std::time::Duration;
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

use crate::model::MotorCtrl;
use crate::ros_adoptor::DiffDrive;

// ===================== Parameters =====================

const NUM_SECTORS: usize = 72;
const SECTOR_ANGLE: f64 = 2.0 * PI / NUM_SECTORS as f64;
const SAFE_DISTANCE: f64 = 0.50;
const CRITICAL_DISTANCE: f64 = 0.30;
const MAX_SPEED: f64 = 0.20;
const CRUISE_SPEED: f64 = 0.15;
const TURN_SPEED: f64 = 0.8;
const CELL_SIZE: f64 = 0.5;
const STUCK_TIMEOUT_SECS: f64 = 8.0;
const DIRECTION_MEMORY: usize = 36;
const OPEN_SPACE_BIAS: f64 = 0.6;
const VFH_THRESHOLD: f64 = 0.3;

// ===================== Explore State =====================

#[derive(Debug, Clone, Copy, PartialEq)]
enum ExploreState {
    Cruise,
    AvoidObstacle,
    StuckRecover,
}

#[derive(Hash, Eq, PartialEq, Clone, Copy)]
struct Cell(i32, i32);

impl Cell {
    fn from_pose(x: f64, y: f64) -> Self {
        Cell((x / CELL_SIZE).floor() as i32, (y / CELL_SIZE).floor() as i32)
    }
}

// ===================== VFH Histogram =====================

struct VfhHistogram {
    density: Vec<f64>,
    ranges: Vec<f64>,
}

impl VfhHistogram {
    fn new() -> Self {
        Self {
            density: vec![0.0; NUM_SECTORS],
            ranges: vec![f64::MAX; NUM_SECTORS],
        }
    }

    fn update(&mut self, ranges: &[f32], angle_min: f32, angle_increment: f32, range_min: f32, range_max: f32) {
        self.density.fill(0.0);
        self.ranges.fill(f64::MAX);

        let n = ranges.len();
        if n == 0 {
            return;
        }

        for (i, &r) in ranges.iter().enumerate() {
            let r = r as f64;
            if (r as f32) < range_min || (r as f32) > range_max {
                continue;
            }

            let angle = angle_min as f64 + i as f64 * angle_increment as f64;
            let normalized = normalize_angle(angle);
            let sector = ((normalized + PI) / SECTOR_ANGLE) as usize % NUM_SECTORS;

            if r < SAFE_DISTANCE * 2.0 {
                let d = (SAFE_DISTANCE * 2.0 - r).max(0.0);
                self.density[sector] += d * d;
            }

            if r < self.ranges[sector] {
                self.ranges[sector] = r;
            }
        }

        // Gaussian smoothing
        let smoothed = self.density.clone();
        let window = 3;
        for i in 0..NUM_SECTORS {
            let mut sum = 0.0;
            let mut weight = 0.0;
            for j in 0..=window {
                let idx1 = (i + j) % NUM_SECTORS;
                let idx2 = (i + NUM_SECTORS - j) % NUM_SECTORS;
                let w = 1.0 / (1.0 + j as f64);
                sum += smoothed[idx1] * w + smoothed[idx2] * w;
                weight += 2.0 * w;
            }
            self.density[i] = sum / weight;
        }
    }

    fn find_candidates(&self) -> Vec<usize> {
        let threshold = VFH_THRESHOLD * VFH_THRESHOLD * 4.0;
        (0..NUM_SECTORS)
            .filter(|&i| self.density[i] < threshold)
            .collect()
    }

    fn sector_to_angle(sector: usize) -> f64 {
        sector as f64 * SECTOR_ANGLE - PI
    }

    fn range_at(&self, sector: usize) -> f64 {
        self.ranges[sector]
    }
}

// ===================== Scan Data =====================

/// Raw scan data passed from main thread
pub struct ScanData {
    pub ranges: Vec<f32>,
    pub angle_min: f32,
    pub angle_increment: f32,
    pub range_min: f32,
    pub range_max: f32,
}

// ===================== Explorer =====================

/// Shared pose for odom -> explorer communication
#[derive(Default, Clone, Copy)]
pub struct SharedPose {
    pub x: f64,
    pub y: f64,
    pub theta: f64,
}

pub struct Explorer {
    drive: DiffDrive,
    command_tx: mpsc::Sender<MotorCtrl>,
    scan_rx: mpsc::Receiver<ScanData>,
    pose: Arc<Mutex<SharedPose>>,
    histogram: VfhHistogram,
    visited: HashSet<Cell>,
    heading_memory: Vec<f64>,
    current_x: f64,
    current_y: f64,
    current_theta: f64,
    state: ExploreState,
    stuck_timer: f64,
    last_x: f64,
    last_y: f64,
}

impl Explorer {
    pub fn new(
        drive: DiffDrive,
        command_tx: mpsc::Sender<MotorCtrl>,
        scan_rx: mpsc::Receiver<ScanData>,
        pose: Arc<Mutex<SharedPose>>,
    ) -> Self {
        Self {
            drive,
            command_tx,
            scan_rx,
            pose,
            histogram: VfhHistogram::new(),
            visited: HashSet::new(),
            heading_memory: Vec::with_capacity(DIRECTION_MEMORY),
            current_x: 0.0,
            current_y: 0.0,
            current_theta: 0.0,
            state: ExploreState::Cruise,
            stuck_timer: 0.0,
            last_x: 0.0,
            last_y: 0.0,
        }
    }

    /// Read pose from shared state
    fn sync_pose(&mut self) {
        if let Ok(sp) = self.pose.lock() {
            self.current_x = sp.x;
            self.current_y = sp.y;
            self.current_theta = sp.theta;
            let cell = Cell::from_pose(sp.x, sp.y);
            self.visited.insert(cell);
        }
    }

    /// Run the explorer loop
    pub async fn run(mut self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        println!("[Explorer] Autonomous exploration started");

        let mut control_interval = tokio::time::interval(Duration::from_millis(100));

        // Wait for hardware init
        tokio::time::sleep(Duration::from_secs(5)).await;

        let _ = self.command_tx
            .send(MotorCtrl::MotorAll(crate::SingleMotorCtrl::HardWareInit))
            .await;
        tokio::time::sleep(Duration::from_secs(2)).await;

        println!("[Explorer] Hardware initialized, starting exploration");

        loop {
            tokio::select! {
                Some(scan) = self.scan_rx.recv() => {
                    self.histogram.update(
                        &scan.ranges,
                        scan.angle_min,
                        scan.angle_increment,
                        scan.range_min,
                        scan.range_max,
                    );
                }
                _ = control_interval.tick() => {
                    self.sync_pose();
                    self.detect_stuck();
                    let (linear, angular) = match self.state {
                        ExploreState::StuckRecover => self.stuck_recover(),
                        _ => self.explore(),
                    };
                    self.send_velocity(linear, angular).await;
                }
            }
        }
    }

    fn explore(&mut self) -> (f64, f64) {
        let front = self.histogram.range_at(NUM_SECTORS / 2);
        let front_left = self.histogram.range_at(NUM_SECTORS / 2 + NUM_SECTORS / 8);
        let front_right = self.histogram.range_at(NUM_SECTORS / 2 - NUM_SECTORS / 8);
        let left = self.histogram.range_at(NUM_SECTORS * 3 / 4);
        let right = self.histogram.range_at(NUM_SECTORS / 4);

        if front < CRITICAL_DISTANCE
            || front_right < CRITICAL_DISTANCE
            || front_left < CRITICAL_DISTANCE
        {
            self.transition_to(ExploreState::AvoidObstacle);
            return self.emergency_avoid(front_left, front_right, left, right);
        }

        if front < SAFE_DISTANCE
            || front_left < SAFE_DISTANCE * 0.8
            || front_right < SAFE_DISTANCE * 0.8
        {
            self.transition_to(ExploreState::AvoidObstacle);
            return self.avoid_obstacle(front, front_left, front_right);
        }

        // VFH direction selection
        let best_direction = self.find_best_direction();
        let target_angle = VfhHistogram::sector_to_angle(best_direction);
        let angle_error = normalize_angle(target_angle - self.current_theta);

        if angle_error.abs() > 0.3 {
            self.transition_to(ExploreState::Cruise);
            let turn = angle_error.signum() * TURN_SPEED * 0.6;
            return (0.05, turn.clamp(-TURN_SPEED, TURN_SPEED));
        }

        self.transition_to(ExploreState::Cruise);
        let angular_cmd = (angle_error * 1.5).clamp(-TURN_SPEED, TURN_SPEED);
        let linear_cmd = CRUISE_SPEED * (1.0 - angle_error.abs() / PI).max(0.3);
        (linear_cmd, angular_cmd)
    }

    fn find_best_direction(&self) -> usize {
        let candidates = self.histogram.find_candidates();
        if candidates.is_empty() {
            return self
                .histogram
                .density
                .iter()
                .enumerate()
                .min_by(|a, b| a.1.partial_cmp(b.1).unwrap())
                .map(|(i, _)| i)
                .unwrap_or(NUM_SECTORS / 2);
        }

        let target_heading = self.current_theta;

        candidates
            .iter()
            .map(|&sector| {
                let angle = VfhHistogram::sector_to_angle(sector);
                let range = self.histogram.range_at(sector);

                let heading_diff = normalize_angle(angle - target_heading).abs();
                let heading_cost = heading_diff / PI;
                let memory_cost = self.heading_memory_cost(angle);
                let coverage_cost = self.coverage_cost(angle, range);
                let distance_reward = if range > SAFE_DISTANCE {
                    OPEN_SPACE_BIAS * (1.0 - SAFE_DISTANCE / range.min(3.0))
                } else {
                    -1.0
                };

                let score = heading_cost * 0.3
                    + memory_cost * 0.35
                    + coverage_cost * 0.25
                    - distance_reward * 0.1;

                (sector, score)
            })
            .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap())
            .map(|(sector, _)| sector)
            .unwrap_or(NUM_SECTORS / 2)
    }

    fn heading_memory_cost(&self, angle: f64) -> f64 {
        if self.heading_memory.is_empty() {
            return 0.0;
        }
        let min_diff = self
            .heading_memory
            .iter()
            .map(|&h| normalize_angle(angle - h).abs())
            .fold(f64::MAX, f64::min);
        if min_diff < 0.26 {
            1.0
        } else if min_diff < 0.52 {
            0.5
        } else {
            0.0
        }
    }

    fn coverage_cost(&self, angle: f64, range: f64) -> f64 {
        let check_dist = range.min(CELL_SIZE * 3.0);
        let check_x = self.current_x + angle.cos() * check_dist;
        let check_y = self.current_y + angle.sin() * check_dist;
        let steps = 4;
        let mut visit_sum = 0.0;
        for i in 1..=steps {
            let t = i as f64 / steps as f64;
            let cx = self.current_x + (check_x - self.current_x) * t;
            let cy = self.current_y + (check_y - self.current_y) * t;
            let cell = Cell::from_pose(cx, cy);
            if self.visited.contains(&cell) {
                visit_sum += 1.0;
            }
        }
        (visit_sum / steps as f64).min(1.0)
    }

    fn emergency_avoid(&self, fl: f64, fr: f64, l: f64, r: f64) -> (f64, f64) {
        let turn = if l > r {
            TURN_SPEED
        } else if r > l {
            -TURN_SPEED
        } else if fl > fr {
            TURN_SPEED * 0.5
        } else {
            -TURN_SPEED * 0.5
        };
        (-0.08, turn)
    }

    fn avoid_obstacle(&self, front: f64, fl: f64, fr: f64) -> (f64, f64) {
        let mut best_angle = 0.0;
        let mut best_score = -f64::MAX;

        for sector in self.histogram.find_candidates() {
            let angle = VfhHistogram::sector_to_angle(sector);
            let rel_angle = normalize_angle(angle - self.current_theta);
            let range = self.histogram.range_at(sector);
            let score = range - rel_angle.abs() * 0.5;
            if score > best_score {
                best_score = score;
                best_angle = rel_angle;
            }
        }

        let turn = best_angle.signum() * TURN_SPEED * 0.7;
        let speed = if front > CRITICAL_DISTANCE + 0.1 {
            0.05
        } else {
            0.0
        };
        (speed, turn.clamp(-TURN_SPEED, TURN_SPEED))
    }

    fn stuck_recover(&mut self) -> (f64, f64) {
        let turn_dir = if self.heading_memory.last().map_or(1.0, |&h| {
            if normalize_angle(h - self.current_theta) > 0.0 {
                -1.0
            } else {
                1.0
            }
        }) > 0.0
        {
            1.0
        } else {
            -1.0
        };
        (-0.1, turn_dir * TURN_SPEED)
    }

    fn detect_stuck(&mut self) {
        let dx = self.current_x - self.last_x;
        let dy = self.current_y - self.last_y;
        let dist = (dx * dx + dy * dy).sqrt();

        if dist < 0.05 {
            self.stuck_timer += 0.1;
        } else {
            self.stuck_timer = 0.0;
            self.last_x = self.current_x;
            self.last_y = self.current_y;
        }

        if self.stuck_timer > STUCK_TIMEOUT_SECS {
            self.transition_to(ExploreState::StuckRecover);
            self.stuck_timer = 0.0;
            let len = self.heading_memory.len();
            if len > 3 {
                self.heading_memory.truncate(len - 3);
            }
        }
    }

    fn transition_to(&mut self, new_state: ExploreState) {
        if self.state != new_state {
            self.state = new_state;
            if self.heading_memory.len() >= DIRECTION_MEMORY {
                self.heading_memory.remove(0);
            }
            self.heading_memory.push(self.current_theta);
        }
    }

    async fn send_velocity(&self, linear: f64, angular: f64) {
        use r2r::geometry_msgs::msg::{Twist, Vector3};

        let twist = Twist {
            linear: Vector3 { x: linear, y: 0.0, z: 0.0 },
            angular: Vector3 { x: 0.0, y: 0.0, z: angular },
        };

        let (v1, v2) = self.drive.encode_cmd(&twist);

        let _ = self.command_tx
            .send(MotorCtrl::Motor0(crate::SingleMotorCtrl::SetTargetVelocity { velocity: v1 }))
            .await;
        let _ = self.command_tx
            .send(MotorCtrl::Motor1(crate::SingleMotorCtrl::SetTargetVelocity { velocity: v2 }))
            .await;
    }
}

fn normalize_angle(mut a: f64) -> f64 {
    while a > PI {
        a -= 2.0 * PI;
    }
    while a < -PI {
        a += 2.0 * PI;
    }
    a
}
