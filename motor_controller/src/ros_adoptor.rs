use std::f64::consts::PI;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures::Stream;
use r2r::QosProfile;
use r2r::geometry_msgs::msg::{
    Point, Pose, PoseWithCovariance, Quaternion, Transform, TransformStamped, Twist,
    TwistWithCovariance, Vector3,
};
use r2r::nav_msgs::msg::Odometry;
use r2r::std_msgs::msg::Header;
use r2r::tf2_msgs::msg::TFMessage;

use crate::model::ImuData;

// ===================== 下位机原始数据 =====================

pub struct MotorInfo {
    pub motor_0_velocity: i32,
    pub motor_1_velocity: i32,
    pub motor_0_position: i32,
    pub motor_1_position: i32,
}

impl ImuData {
    /// yaw 角速度 deg/s → rad/s
    pub fn yaw_rate_rad(&self) -> f64 {
        (self.angz as f64) * PI / 180.0
    }
}

// ===================== 差速驱动 =====================
#[derive(Clone)]
pub struct DiffDrive {
    pub wheel_radius: f64,
    pub wheel_separation: f64,
    pulses_per_rev: f64,
    gear_ratio: f64,
}

impl DiffDrive {
    pub const fn new(
        wheel_radius: f64,
        wheel_separation: f64,
        pulses_per_rev: f64,
        gear_ratio: f64,
    ) -> Self {
        Self {
            wheel_radius,
            wheel_separation,
            pulses_per_rev,
            gear_ratio,
        }
    }

    fn ticks_per_rev(&self) -> f64 {
        self.pulses_per_rev * self.gear_ratio
    }

    pub fn pulses_to_rad(&self, pulses: f64) -> f64 {
        pulses / self.ticks_per_rev() * 2.0 * PI
    }

    pub fn rad_to_pulses(&self, rad: f64) -> f64 {
        rad * self.ticks_per_rev() / (2.0 * PI)
    }

    pub fn angular_to_linear(&self, rad: f64) -> f64 {
        rad * self.wheel_radius
    }

    pub fn decode_motor(&self, motor: &MotorInfo) -> WheelData {
        WheelData {
            left_pos: self.pulses_to_rad(-(motor.motor_0_position as f64)),
            right_pos: self.pulses_to_rad(motor.motor_1_position as f64),
            left_vel: self.pulses_to_rad(-(motor.motor_0_velocity as f64)),
            right_vel: self.pulses_to_rad(motor.motor_1_velocity as f64),
        }
    }

    pub fn encode_cmd(&self, twist: &Twist) -> (i32, i32) {
        let v = twist.linear.x;
        let omega = twist.angular.z;

        let v_left = v - (omega * self.wheel_separation / 2.0);
        let v_right = v + (omega * self.wheel_separation / 2.0);

        let p_left = self.rad_to_pulses(v_left / self.wheel_radius);
        let p_right = self.rad_to_pulses(v_right / self.wheel_radius);

        (p_left as i32, p_right as i32)
    }
}

const COV: [f64; 36] = [
    0.01, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 99999.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 99999.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 99999.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.01,
];

// ===================== 数据结构 =====================

#[derive(Default, Clone, Copy)]
pub struct WheelData {
    pub left_pos: f64,
    pub right_pos: f64,
    pub left_vel: f64,
    pub right_vel: f64,
}

#[derive(Default, Clone, Copy)]
pub struct OdomPose {
    pub x: f64,
    pub y: f64,
    pub theta: f64,
    pub vx: f64,
    pub wz: f64,
}

// ===================== 里程计（轮子 + IMU 融合） =====================

pub struct OdomCalculator {
    drive: DiffDrive,
    pose: OdomPose,
    prev_l: Option<f64>,
    prev_r: Option<f64>,
    prev_yaw: Option<f64>,
}

impl OdomCalculator {
    pub fn new(drive: DiffDrive) -> Self {
        Self {
            drive,
            pose: OdomPose::default(),
            prev_l: None,
            prev_r: None,
            prev_yaw: None,
        }
    }

    pub fn pose(&self) -> OdomPose {
        self.pose
    }

    /// 轮子算位移 + IMU 算航向
    pub fn update(&mut self, w: &WheelData, imu: &ImuData) -> OdomPose {
        // ---- 轮子：用位置差分算线位移 ----
        if let (Some(pl), Some(pr)) = (self.prev_l, self.prev_r) {
            let dl = self.drive.angular_to_linear(w.left_pos - pl);
            let dr = self.drive.angular_to_linear(w.right_pos - pr);
            let d_center = (dl + dr) / 2.0;

            if d_center.abs() > 1e-8 {
                let mid = self.pose.theta
                    + (dr - dl) / self.drive.wheel_separation / 2.0;
                self.pose.x += d_center * mid.cos();
                self.pose.y += d_center * mid.sin();
            }
        }
        self.prev_l = Some(w.left_pos);
        self.prev_r = Some(w.right_pos);

        // ---- IMU：直接用航向角（angz 是角度，不是角速度）----
        self.pose.theta = norm(imu.angz as f64 * PI / 180.0);

        // ---- 速度：轮子线速度 + IMU 角速度（从角度差分计算）----
        let vl = self.drive.angular_to_linear(w.left_vel);
        let vr = self.drive.angular_to_linear(w.right_vel);
        self.pose.vx = (vl + vr) / 2.0;

        // 角速度 = 角度差分 / 时间间隔
        if let Some(prev_yaw) = self.prev_yaw {
            let current_yaw = imu.angz as f64;
            let mut dyaw = current_yaw - prev_yaw;
            // 处理 ±180° 跨越
            if dyaw > 180.0 {
                dyaw -= 360.0;
            } else if dyaw < -180.0 {
                dyaw += 360.0;
            }
            self.pose.wz = dyaw * PI / 180.0 / 0.02; // deg → rad/s
        }
        self.prev_yaw = Some(imu.angz as f64);

        self.pose
    }
}

// ===================== Base Controller =====================

pub struct BaseController {
    node: r2r::Node,
    drive: DiffDrive,
    odom_pub: r2r::Publisher<Odometry>,
    tf_pub: r2r::Publisher<TFMessage>,
    odom: OdomCalculator,
}

impl BaseController {
    pub fn init(
        wheel_radius: f64,
        wheel_separation: f64,
        pulses_per_rev: f64,
        gear_ratio: f64,
    ) -> Result<(Self, impl Stream<Item = Twist> + Send + Unpin), Box<dyn std::error::Error>> {
        let ctx = r2r::Context::create()?;
        let mut node = r2r::Node::create(ctx, "base_controller", "")?;
        let cmd_stream = node.subscribe::<Twist>("/cmd_vel", QosProfile::default())?;
        let odom_pub = node.create_publisher::<Odometry>("/odom", QosProfile::default())?;
        let tf_pub = node.create_publisher::<TFMessage>("/tf", QosProfile::default())?;
        r2r::log_info!("base_controller", "initialized");

        let drive = DiffDrive::new(wheel_radius, wheel_separation, pulses_per_rev, gear_ratio);

        let ctrl = Self {
            node,
            drive: DiffDrive::new(wheel_radius, wheel_separation, pulses_per_rev, gear_ratio),
            odom_pub,
            tf_pub,
            odom: OdomCalculator::new(drive),
        };

        Ok((ctrl, cmd_stream))
    }

    pub fn driver(&self) -> DiffDrive {
        self.drive.clone()
    }

    pub fn spin(&mut self) {
        self.node.spin_once(Duration::ZERO)
    }

    pub fn encode_cmd(&self, twist: &Twist) -> (i32, i32) {
        self.drive.encode_cmd(twist)
    }

    /// 电机 + IMU → 更新里程计 → 发布 /odom + TF
    pub fn push_data(&mut self, motor: &MotorInfo, imu: &ImuData) -> Result<OdomPose, r2r::Error> {
        let w = self.drive.decode_motor(motor);
        let pose = self.odom.update(&w, imu);
        eprintln!("[ODOM] x={:.4} y={:.4} theta={:.2}deg | L_pos={:.2} R_pos={:.2} L_vel={:.2} R_vel={:.2}",
            pose.x, pose.y, pose.theta * 180.0 / std::f64::consts::PI,
            w.left_pos, w.right_pos, w.left_vel, w.right_vel);
        let stamp = stamp_now();
        let orientation = yaw_to_quat(pose.theta);
        self.odom_pub.publish(&Odometry {
            header: Header {
                stamp: stamp.clone(),
                frame_id: "odom".into(),
            },
            child_frame_id: "base_link".into(),
            pose: PoseWithCovariance {
                pose: Pose {
                    position: Point {
                        x: pose.x,
                        y: pose.y,
                        z: 0.0,
                    },
                    orientation: orientation.clone(),
                },
                covariance: COV.to_vec(),
            },
            twist: TwistWithCovariance {
                twist: Twist {
                    linear: Vector3 {
                        x: pose.vx,
                        y: 0.0,
                        z: 0.0,
                    },
                    angular: Vector3 {
                        x: 0.0,
                        y: 0.0,
                        z: pose.wz,
                    },
                },
                ..Default::default()
            },
        })?;

        // 2. 发布 TF: odom → base_link
        self.tf_pub.publish(&TFMessage {
            transforms: vec![TransformStamped {
                header: Header {
                    stamp,
                    frame_id: "odom".into(),
                },
                child_frame_id: "base_link".into(),
                transform: Transform {
                    translation: Vector3 {
                        x: pose.x,
                        y: pose.y,
                        z: 0.0,
                    },
                    rotation: orientation,
                },
            }],
        })?;

        Ok(pose)
    }
}

// ===================== 工具 =====================

fn norm(mut a: f64) -> f64 {
    while a > PI {
        a -= 2.0 * PI;
    }
    while a < -PI {
        a += 2.0 * PI;
    }
    a
}

fn yaw_to_quat(yaw: f64) -> Quaternion {
    Quaternion {
        x: 0.0,
        y: 0.0,
        z: (yaw / 2.0).sin(),
        w: (yaw / 2.0).cos(),
    }
}

fn stamp_now() -> r2r::builtin_interfaces::msg::Time {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    r2r::builtin_interfaces::msg::Time {
        sec: d.as_secs() as i32,
        nanosec: d.subsec_nanos(),
    }
}
